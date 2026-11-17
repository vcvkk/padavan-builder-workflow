# tg-ws-proxy-rs: transparent fork for Padavan

Fork of [valnesfjord/tg-ws-proxy-rs](https://github.com/valnesfjord/tg-ws-proxy-rs)
at upstream commit `53f3922` (v2.7.0), MIT licensed (see `LICENSE`). Only the
parts needed to build and test the binary are vendored (no Android app, docs,
OpenWrt packaging).

## What the fork adds

A third listener, `--transparent-enabled`, for connections a router
redirects with iptables `REDIRECT`. Telegram apps on the LAN need no proxy
settings at all.

- The destination the app dialled is read with `SO_ORIGINAL_DST` and routed
  exactly like a SOCKS5 destination: the built-in DC map, then the DC named
  in the obfuscated header (`--socks-dc` overrides apply).
- Everything the WebSocket bridge cannot carry (t.me and web.telegram.org
  over TLS/HTTP, the HTTP transport, call relays over TCP, CDN addresses with
  no known DC) is **spliced to the original destination** with the sniffed
  bytes replayed, so interception never breaks anything that worked before.
- Sniffing is bounded at 2 s so server-speaks-first protocols are passed on
  quickly; TLS/HTTP openings are recognised by whole 4-byte prefixes, never
  by a single byte (a random obfuscated init starts with a capital letter one
  time in ten).

Flags: `--transparent-enabled`, `--transparent-host` (default `0.0.0.0`),
`--transparent-port` (default `1090`); env `TG_TRANSPARENT_*`.

Code: `src/inbound/transparent.rs` (+ tests), a `Reject::Splice` outcome in
`src/inbound.rs`, and `Transport::obfuscated` factored out of
`src/inbound/socks.rs` so both inbounds share it.

## Verified

- `cargo test`: the new transparent tests plus the upstream suite.
- End to end in a Linux netns: iptables `REDIRECT` → transparent listener →
  `wss://kws2/kws4.web.telegram.org` → real `req_pq_multi` / `resPQ` with
  DC2 and DC4, abridged and intermediate, ports 443 and 80; TLS to
  web.telegram.org spliced.

## Router integration

See `../tgwsproxy/padavan/`: `tgwsproxy.sh` (service + iptables rules),
`integrate.sh` (wires it into padavan-ng: rc, httpd, web UI), built by
`../.github/workflows/build.yml` for `mipsel-unknown-linux-musl`.

## Size for 8 MB routers

`env-filter` (RUST_LOG directives, pulls in a regex engine) is now a default
feature. Router builds use `--no-default-features`, where `RUST_LOG` may
still name a single level (`warn`, `info`, ...), plus
`-Z build-std-features=optimize_for_size`: 1.19 MB → 0.94 MB xz-compressed
for mipsel.
