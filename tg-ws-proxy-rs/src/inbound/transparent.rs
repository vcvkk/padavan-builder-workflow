//! A transparent entrance for Telegram apps that were never told about a
//! proxy: a router redirects their connections here with iptables
//! `REDIRECT`, and the kernel still knows the address each one dialled.
//!
//! Past `SO_ORIGINAL_DST`, a redirected client is a SOCKS5 client whose
//! CONNECT has already happened — the same secretless transports, the same
//! destination → DC map, the same header fallback — so it joins the shared
//! ladder as one.
//!
//! What differs is consent. Nothing here was configured by the client, and
//! the redirected ranges carry more than MTProto to a DC: t.me and
//! web.telegram.org over TLS/HTTP, the HTTP transport, call relays over TCP,
//! CDN DCs the map does not know. Rejecting those, as the SOCKS listener
//! rightly does, would break them for every device on the network. Instead a
//! connection the bridge cannot carry is spliced to the address it dialled,
//! with the bytes already read replayed first: interception can only route
//! Telegram better, never make anything worse than no proxy at all.
//!
//! Sniffing is bounded separately from the handshake timeout: a protocol
//! where the server speaks first sends the client nothing to sniff, and must
//! reach its server long before the handshake timeout would drop it.

use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info};

use super::socks::{ReportKind, Transport, dc_label, destination_dc, first_report, is_telegram};
use super::{ClientReader, ClientWriter, Inbound, Link, Reject, Session};
use crate::config::Config;
use crate::crypto::ProtoTag;
use crate::runtime::Runtime;

/// How long a redirected client may take to send enough of its first bytes
/// to tell MTProto from anything else. Real clients send their 64-byte init
/// in the first segment; only a server-speaks-first protocol waits it out.
const SNIFF_WAIT: Duration = Duration::from_secs(2);

/// A redirected connection the bridge will not carry.
pub(crate) struct Splice {
    stream: TcpStream,
    /// Where the client was going before the redirect.
    dest: SocketAddr,
    /// What was read while sniffing, owed to `dest` before anything else.
    head: Vec<u8>,
    why: &'static str,
}

/// What the first bytes of a redirected connection turned out to be.
enum Sniffed {
    Mtproto(Box<Transport>),
    Other,
}

/// Whether four opening bytes start a TLS record or an HTTP request.
///
/// Matched on whole prefixes, never a first byte alone: an obfuscated init is
/// random, so one byte in ten would open with a capital letter. Clients redraw
/// any init that starts with `HEAD`, `POST`, `GET `, `OPTI` or a TLS record,
/// which keeps these prefixes unambiguous; the rest are improbable enough at
/// 2^-32, and a false match only costs that one connection its route.
fn is_tls_or_http(first: &[u8]) -> bool {
    const HTTP: [&[u8; 4]; 8] = [
        b"GET ", b"POST", b"HEAD", b"OPTI", b"PUT ", b"DELE", b"CONN", b"PATC",
    ];
    matches!(first, [0x16, 0x03, 0..=4, _]) || HTTP.iter().any(|m| first == &m[..])
}

/// Read just enough of the client's first bytes to classify them, keeping
/// every byte in `head` for a possible splice.
async fn sniff(stream: &mut TcpStream, head: &mut Vec<u8>) -> io::Result<Sniffed> {
    let deadline = tokio::time::Instant::now() + SNIFF_WAIT;
    let mut header = [0u8; 64];
    let mut filled = 0;
    let mut want = 1;
    loop {
        while filled < want {
            let read = tokio::time::timeout_at(deadline, stream.read(&mut header[filled..want]));
            match read.await {
                Ok(Ok(0)) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(Ok(n)) => {
                    head.extend_from_slice(&header[filled..filled + n]);
                    filled += n;
                }
                Ok(Err(e)) => return Err(e),
                Err(_) => return Ok(Sniffed::Other),
            }
        }
        match want {
            1 if header[0] == 0xef => {
                return Ok(Sniffed::Mtproto(Box::new(Transport::plain(
                    ProtoTag::Abridged,
                ))));
            }
            1 => want = 4,
            4 => {
                if let Some(proto) = ProtoTag::from_bytes(&header[..4]) {
                    return Ok(Sniffed::Mtproto(Box::new(Transport::plain(proto))));
                }
                // A TLS record or an HTTP request can be shorter than 64
                // bytes and then waits for the server: decide before reading
                // on.
                if is_tls_or_http(&header[..4]) {
                    return Ok(Sniffed::Other);
                }
                want = 64;
            }
            _ => {
                return Ok(match Transport::obfuscated(&header) {
                    Some(transport) => Sniffed::Mtproto(Box::new(transport)),
                    None => Sniffed::Other,
                });
            }
        }
    }
}

/// The address a redirected connection was originally bound for.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn original_dst(stream: &TcpStream) -> io::Result<SocketAddr> {
    use std::mem::{size_of, zeroed};
    use std::net::Ipv6Addr;
    use std::os::fd::AsRawFd;

    // linux/netfilter_ipv4.h SO_ORIGINAL_DST, linux/netfilter_ipv6/ip6_tables.h
    // IP6T_SO_ORIGINAL_DST: the same number at different levels.
    const SO_ORIGINAL_DST: libc::c_int = 80;

    let fd = stream.as_raw_fd();
    // A dual-stack listener sees IPv4 clients as v4-mapped; their conntrack
    // entry is still IPv4, and only SOL_IP finds it.
    let local_v4 = match stream.local_addr()? {
        SocketAddr::V4(_) => true,
        SocketAddr::V6(v6) => v6.ip().to_ipv4_mapped().is_some(),
    };
    if local_v4 {
        // SAFETY: getsockopt fills at most `len` bytes of a zeroed sockaddr_in.
        let mut addr: libc::sockaddr_in = unsafe { zeroed() };
        let mut len = size_of::<libc::sockaddr_in>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_IP,
                SO_ORIGINAL_DST,
                (&mut addr as *mut libc::sockaddr_in).cast(),
                &mut len,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(SocketAddr::new(
            Ipv4Addr::from(u32::from_be(addr.sin_addr.s_addr)).into(),
            u16::from_be(addr.sin_port),
        ))
    } else {
        // SAFETY: as above, for sockaddr_in6.
        let mut addr: libc::sockaddr_in6 = unsafe { zeroed() };
        let mut len = size_of::<libc::sockaddr_in6>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_IPV6,
                SO_ORIGINAL_DST,
                (&mut addr as *mut libc::sockaddr_in6).cast(),
                &mut len,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(SocketAddr::new(
            Ipv6Addr::from(addr.sin6_addr.s6_addr).into(),
            u16::from_be(addr.sin6_port),
        ))
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn original_dst(_stream: &TcpStream) -> io::Result<SocketAddr> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "SO_ORIGINAL_DST is Linux-only",
    ))
}

/// The transparent listener (`--transparent-enabled`).
pub(crate) struct Transparent;

impl Transparent {
    /// Classify a client already known to be bound for `dest`.
    pub(crate) async fn route(
        mut stream: TcpStream,
        peer: SocketAddr,
        dest: SocketAddr,
        config: &Config,
    ) -> Result<Session, Reject> {
        let ip = dest.ip().to_canonical();
        let mapped = destination_dc(ip, config);
        let mut head = Vec::new();
        let splice = |stream, head, why| {
            Reject::Splice(Box::new(Splice {
                stream,
                dest,
                head,
                why,
            }))
        };
        if mapped.is_none() && !is_telegram(ip) {
            // The router redirected more than Telegram; not ours to touch.
            return Err(splice(stream, head, "not a Telegram address"));
        }
        let transport = match sniff(&mut stream, &mut head).await {
            Ok(Sniffed::Mtproto(transport)) => transport,
            Ok(Sniffed::Other) => return Err(splice(stream, head, "not an MTProto transport")),
            Err(error) => {
                debug!("[{}] transparent client to {} gone: {}", peer, dest, error);
                return Err(Reject::Close);
            }
        };
        let dc_idx = match (mapped, transport.named_dc) {
            (Some(dc), _) => dc,
            (None, Some(dc)) => {
                if first_report(ip, ReportKind::HeaderDc) {
                    info!(
                        "transparent destination {} is not in the DC map; routing it as {} by \
                         its transport header (pin it with --socks-dc {}:{})",
                        ip,
                        dc_label(dc),
                        dc,
                        ip
                    );
                }
                dc
            }
            (None, None) => return Err(splice(stream, head, "no DC known for this address")),
        };
        let (reader, writer) = stream.into_split();
        Ok(Session {
            reader: ClientReader::Plain(reader),
            writer: ClientWriter::Plain(writer),
            dc_idx,
            proto: transport.proto,
            obfuscation: transport.obfuscation,
        })
    }
}

impl Inbound for Transparent {
    const NAME: &'static str = "transparent";

    async fn handshake(
        &self,
        stream: TcpStream,
        peer: SocketAddr,
        config: &Config,
    ) -> Result<Session, Reject> {
        let dest = match original_dst(&stream) {
            Ok(dest) => dest,
            Err(error) => {
                debug!("[{}] transparent: no original destination: {}", peer, error);
                return Err(Reject::Close);
            }
        };
        // Dialled directly rather than redirected: splicing would loop.
        if stream.local_addr().is_ok_and(|local| local == dest) {
            debug!("[{}] transparent listener dialled directly", peer);
            return Err(Reject::Close);
        }
        Self::route(stream, peer, dest, config).await
    }

    /// None: clients reach this listener only through the router's redirect.
    fn links(&self, _addr: SocketAddr, _config: &Config) -> Vec<Link> {
        Vec::new()
    }
}

/// Connect a spliced client to where it was going and copy both ways until
/// either side is done.
pub(crate) async fn splice(
    splice: Splice,
    peer: SocketAddr,
    config: Arc<Config>,
    runtime: Arc<Runtime>,
) {
    let Splice {
        mut stream,
        dest,
        head,
        why,
    } = splice;
    let ip: IpAddr = dest.ip().to_canonical();
    if first_report(ip, ReportKind::Spliced) {
        info!(
            "transparent: {} ({}) goes direct, as without the proxy",
            dest, why
        );
    } else {
        debug!("[{}] transparent: {} ({}) goes direct", peer, dest, why);
    }
    let timeout = Duration::from_secs(config.tcp_fallback_timeout);
    let mut upstream = match runtime
        .outbound()
        .connect(&ip.to_string(), dest.port(), timeout)
        .await
    {
        Ok(upstream) => upstream,
        Err(error) => {
            debug!("[{}] transparent: direct {} failed: {}", peer, dest, error);
            return;
        }
    };
    let _ = upstream.set_nodelay(true);
    if !head.is_empty()
        && let Err(error) = upstream.write_all(&head).await
    {
        debug!("[{}] transparent: direct {} write: {}", peer, dest, error);
        return;
    }
    drop(head);
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut upstream).await;
}

#[cfg(test)]
mod tests;
