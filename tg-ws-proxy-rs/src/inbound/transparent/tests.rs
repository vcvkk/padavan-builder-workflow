use super::*;

use clap::Parser;
use tokio::net::TcpListener;

use crate::crypto::generate_relay_init;
use crate::outbound::OutboundConnector;

/// A connected `(client, accepted)` pair on loopback.
async fn pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (accepted, _) = listener.accept().await.unwrap();
    (client, accepted)
}

fn config() -> Config {
    Config::try_parse_from(["test"]).unwrap()
}

fn peer() -> SocketAddr {
    "192.168.1.50:50000".parse().unwrap()
}

#[tokio::test]
async fn a_direct_client_init_is_mtproto_naming_its_dc() {
    let (mut client, mut accepted) = pair().await;
    let init = generate_relay_init(ProtoTag::PaddedIntermediate, -4);
    client.write_all(&init).await.unwrap();

    let mut head = Vec::new();
    let Sniffed::Mtproto(transport) = sniff(&mut accepted, &mut head).await.unwrap() else {
        panic!("not sniffed as MTProto");
    };
    assert_eq!(transport.proto, ProtoTag::PaddedIntermediate);
    assert_eq!(transport.named_dc, Some(-4));
    assert!(transport.obfuscation.is_some());
    assert_eq!(head, init);
}

#[tokio::test]
async fn plain_transports_are_mtproto_without_reading_further() {
    for (first, proto) in [
        (&[0xef][..], ProtoTag::Abridged),
        (&[0xee, 0xee, 0xee, 0xee][..], ProtoTag::Intermediate),
    ] {
        let (mut client, mut accepted) = pair().await;
        client.write_all(first).await.unwrap();
        let mut head = Vec::new();
        let Sniffed::Mtproto(transport) = sniff(&mut accepted, &mut head).await.unwrap() else {
            panic!("{proto:?} not sniffed as MTProto");
        };
        assert_eq!(transport.proto, proto);
        assert!(transport.obfuscation.is_none());
        assert_eq!(head, first);
    }
}

#[tokio::test]
async fn short_tls_and_http_openings_are_not_waited_on() {
    for opening in [
        &b"\x16\x03\x01\x00\x05hello"[..],
        &b"GET / HTTP/1.1\r\nHost: t.me\r\n\r\n"[..],
    ] {
        let (mut client, mut accepted) = pair().await;
        client.write_all(opening).await.unwrap();
        let mut head = Vec::new();
        let sniffed =
            tokio::time::timeout(Duration::from_millis(500), sniff(&mut accepted, &mut head))
                .await
                .expect("sniff waited for more bytes")
                .unwrap();
        assert!(matches!(sniffed, Sniffed::Other));
        assert_eq!(head, &opening[..head.len()]);
        assert!(!head.is_empty());
    }
}

#[tokio::test]
async fn an_init_opening_with_a_capital_letter_is_still_mtproto() {
    let init = std::iter::repeat_with(|| generate_relay_init(ProtoTag::Intermediate, 2))
        .find(|init| init[0].is_ascii_uppercase())
        .unwrap();
    let (mut client, mut accepted) = pair().await;
    client.write_all(&init).await.unwrap();
    let mut head = Vec::new();
    assert!(matches!(
        sniff(&mut accepted, &mut head).await.unwrap(),
        Sniffed::Mtproto(_)
    ));
}

#[test]
fn tls_and_http_are_told_by_whole_prefixes() {
    for opening in [
        &b"\x16\x03\x01\x02"[..],
        b"\x16\x03\x03\x00",
        b"GET ",
        b"POST",
        b"CONN",
    ] {
        assert!(is_tls_or_http(opening), "{opening:?}");
    }
    for opening in [
        &b"GETX"[..],
        b"Post",
        b"\x16\x04\x01\x02",
        b"\xef\x00\x00\x00",
    ] {
        assert!(!is_tls_or_http(opening), "{opening:?}");
    }
}

#[tokio::test]
async fn sixty_four_bytes_that_decrypt_to_no_transport_are_not_mtproto() {
    let (mut client, mut accepted) = pair().await;
    let noise: Vec<u8> = (0u8..64).map(|i| i.wrapping_mul(37) | 0x80).collect();
    client.write_all(&noise).await.unwrap();
    let mut head = Vec::new();
    assert!(matches!(
        sniff(&mut accepted, &mut head).await.unwrap(),
        Sniffed::Other
    ));
    assert_eq!(head, noise);
}

#[tokio::test]
async fn a_silent_client_is_given_up_on_after_the_sniff_wait() {
    let (_client, mut accepted) = pair().await;
    let mut head = Vec::new();
    assert!(matches!(
        sniff(&mut accepted, &mut head).await.unwrap(),
        Sniffed::Other
    ));
    assert!(head.is_empty());
}

#[tokio::test]
async fn a_mapped_dc_address_becomes_a_session_for_that_dc() {
    let (mut client, accepted) = pair().await;
    // Android names a random DC without a secret: the map must win.
    client
        .write_all(&generate_relay_init(ProtoTag::Intermediate, 3))
        .await
        .unwrap();
    let dest = "149.154.167.51:443".parse().unwrap();
    let Ok(session) = Transparent::route(accepted, peer(), dest, &config()).await else {
        panic!("mapped DC2 address was not routed");
    };
    assert_eq!(session.dc_idx, 2);
    assert_eq!(session.proto, ProtoTag::Intermediate);
}

#[tokio::test]
async fn an_unmapped_telegram_address_uses_the_header_dc() {
    let (mut client, accepted) = pair().await;
    client
        .write_all(&generate_relay_init(ProtoTag::Abridged, -5))
        .await
        .unwrap();
    let dest = "91.108.57.250:443".parse().unwrap();
    let Ok(session) = Transparent::route(accepted, peer(), dest, &config()).await else {
        panic!("header DC was not used");
    };
    assert_eq!(session.dc_idx, -5);
}

#[tokio::test]
async fn what_the_bridge_cannot_carry_is_spliced_with_its_bytes() {
    // web.telegram.org / t.me: TLS on a Telegram address outside the DC map.
    let (mut client, accepted) = pair().await;
    client.write_all(b"\x16\x03\x01\x02\x00").await.unwrap();
    let dest = "149.154.167.99:443".parse().unwrap();
    match Transparent::route(accepted, peer(), dest, &config()).await {
        Err(Reject::Splice(splice)) => {
            assert_eq!(splice.dest, dest);
            assert_eq!(splice.head[0], 0x16);
        }
        _ => panic!("TLS was not spliced"),
    }

    // An unmapped address whose obfuscated header names no production DC.
    let (mut client, accepted) = pair().await;
    client
        .write_all(&generate_relay_init(ProtoTag::Intermediate, 77))
        .await
        .unwrap();
    let dest = "91.108.57.250:443".parse().unwrap();
    match Transparent::route(accepted, peer(), dest, &config()).await {
        Err(Reject::Splice(splice)) => assert_eq!(splice.head.len(), 64),
        _ => panic!("DC-less MTProto was not spliced"),
    }
}

#[tokio::test]
async fn non_telegram_destinations_are_spliced_unread() {
    let (_client, accepted) = pair().await;
    let dest = "8.8.8.8:443".parse().unwrap();
    match Transparent::route(accepted, peer(), dest, &config()).await {
        Err(Reject::Splice(splice)) => assert!(splice.head.is_empty()),
        _ => panic!("non-Telegram destination was not spliced"),
    }
}

#[tokio::test]
async fn a_splice_replays_the_sniffed_bytes_then_relays_both_ways() {
    let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dest = server.local_addr().unwrap();
    let echo = tokio::spawn(async move {
        let (mut conn, _) = server.accept().await.unwrap();
        let mut buf = [0u8; 64];
        loop {
            let n = conn.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            conn.write_all(&buf[..n]).await.unwrap();
        }
    });

    let (mut client, accepted) = pair().await;
    client.write_all(b"GET /").await.unwrap();
    let Err(Reject::Splice(spliced)) = Transparent::route(accepted, peer(), dest, &config()).await
    else {
        panic!("loopback destination was not spliced");
    };
    let runtime = Arc::new(Runtime::new(OutboundConnector::direct()));
    let relay = tokio::spawn(splice(*spliced, peer(), Arc::new(config()), runtime));

    client.write_all(b" HTTP/1.1").await.unwrap();
    let mut got = vec![0u8; b"GET / HTTP/1.1".len()];
    client.read_exact(&mut got).await.unwrap();
    assert_eq!(got, b"GET / HTTP/1.1");

    drop(client);
    relay.await.unwrap();
    echo.await.unwrap();
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn an_unredirected_connection_reports_its_own_destination() {
    // Without a NAT entry the kernel answers with the tuple as dialled, or
    // ENOENT when conntrack is not loaded; either way no foreign address.
    let (_client, accepted) = pair().await;
    if let Ok(dest) = original_dst(&accepted) {
        assert_eq!(dest, accepted.local_addr().unwrap());
    }
}
