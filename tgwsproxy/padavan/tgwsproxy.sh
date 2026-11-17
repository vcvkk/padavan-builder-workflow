#!/bin/sh
# Transparent Telegram proxy for Padavan: tg-ws-proxy-rs plus the iptables
# rules that steer LAN Telegram traffic into it. No client configuration.
#
#   start    run the proxy (if tgwsp_enable=1) and install the rules
#   stop     remove the rules and stop the proxy
#   restart  stop, then start
#   reload   called after every firewall rebuild: reinstall the rules,
#            starting the proxy first if it is enabled but not running
#
# nvram: tgwsp_enable 0|1, tgwsp_ipv6 0|1 (refuse Telegram over IPv6 so apps
# fall back to the redirected IPv4), tgwsp_log 0|1, tgwsp_args (extra
# tg-ws-proxy flags), tgwsp_secret (generated on first start).

BIN=/usr/bin/tg-ws-proxy
TAG=tg-ws-proxy
PIDFILE=/var/run/tgwsproxy.pid
TPORT=1090
MPORT=1443
CHAIN=TGWSP
CHAIN6=TGWSP6

# https://core.telegram.org/resources/cidr.txt, plus the DC2 block at
# 95.161.64.0/20. Anything in here that is not MTProto to a DC (t.me,
# web.telegram.org, call relays over TCP) is passed through untouched by
# the proxy itself.
RANGES4="91.108.56.0/22 91.108.4.0/22 91.108.8.0/22 91.108.16.0/22
91.108.12.0/22 149.154.160.0/20 91.105.192.0/23 91.108.20.0/22
185.76.151.0/24 95.161.64.0/20"
RANGES6="2001:b28:f23d::/48 2001:b28:f23f::/48 2001:67c:4e8::/48
2001:b28:f23c::/48 2a0a:f280::/32"

log() { logger -t "$TAG" "$*"; }

lan_if() { i="$(nvram get lan_ifname)"; echo "${i:-br0}"; }
lan_ip() { nvram get lan_ipaddr; }
enabled() { [ "$(nvram get tgwsp_enable)" = "1" ]; }

running() {
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

secret() {
	s="$(nvram get tgwsp_secret)"
	if ! echo "$s" | grep -qE '^[0-9a-f]{32}$'; then
		s="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
		nvram set tgwsp_secret="$s"
		nvram commit
	fi
	echo "$s"
}

fw_del() {
	iface="$(lan_if)"
	while iptables -t nat -D PREROUTING -i "$iface" -p tcp -j $CHAIN 2>/dev/null; do :; done
	iptables -t nat -F $CHAIN 2>/dev/null
	iptables -t nat -X $CHAIN 2>/dev/null
	if command -v ip6tables >/dev/null 2>&1; then
		while ip6tables -D FORWARD -i "$iface" -j $CHAIN6 2>/dev/null; do :; done
		ip6tables -F $CHAIN6 2>/dev/null
		ip6tables -X $CHAIN6 2>/dev/null
	fi
}

fw_add() {
	fw_del
	iface="$(lan_if)"
	modprobe -q ipt_REDIRECT 2>/dev/null
	iptables -t nat -N $CHAIN || return 1
	for net in $RANGES4; do
		iptables -t nat -A $CHAIN -d "$net" -p tcp -j REDIRECT --to-ports $TPORT
	done
	iptables -t nat -I PREROUTING -i "$iface" -p tcp -j $CHAIN

	# The kernel has no IPv6 NAT to redirect with; refusing Telegram's v6
	# ranges makes apps retry over IPv4 at once instead of timing out.
	if [ "$(nvram get tgwsp_ipv6)" != "0" ] && command -v ip6tables >/dev/null 2>&1; then
		ip6tables -N $CHAIN6 && {
			for net in $RANGES6; do
				ip6tables -A $CHAIN6 -d "$net" -p tcp -j REJECT --reject-with tcp-reset
			done
			ip6tables -I FORWARD -i "$iface" -j $CHAIN6
		}
	fi
}

start() {
	enabled || return 0
	[ -x "$BIN" ] || { log "$BIN is missing"; return 1; }
	running && return 0

	ip="$(lan_ip)"
	sec="$(secret)"
	# Warnings and errors always reach syslog; every connection only on request.
	level=warn
	[ "$(nvram get tgwsp_log)" = "1" ] && level=info
	# Word splitting of tgwsp_args is intended: it holds extra flags.
	args="--host $ip --port $MPORT --link-ip $ip --secret $sec \
--transparent-enabled --transparent-host $ip --transparent-port $TPORT \
--pool-size 2 $(nvram get tgwsp_args)"

	(
		trap 'exit 0' TERM
		export RUST_LOG=$level
		while :; do
			# shellcheck disable=SC2086
			"$BIN" $args 2>&1 | logger -t "$TAG"
			sleep 5
			log "restarting after exit"
		done
	) </dev/null >/dev/null 2>&1 &
	echo $! > "$PIDFILE"

	fw_add && log "started: Telegram on $(lan_if) is proxied transparently"
}

stop() {
	fw_del
	if [ -f "$PIDFILE" ]; then
		kill "$(cat "$PIDFILE")" 2>/dev/null
		rm -f "$PIDFILE"
	fi
	killall -q tg-ws-proxy 2>/dev/null
	return 0
}

case "$1" in
start) start ;;
stop) stop ;;
restart) stop; start ;;
reload)
	if ! enabled; then
		running && stop
	elif running; then
		fw_add
	else
		start
	fi
	;;
*) echo "Usage: $0 {start|stop|restart|reload}"; exit 1 ;;
esac
