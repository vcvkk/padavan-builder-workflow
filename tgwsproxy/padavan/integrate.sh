#!/bin/bash
# Wire tg-ws-proxy (transparent Telegram proxy) into a padavan-ng tree:
# package dir, build flag, rc service + firewall hook, nvram defaults,
# httpd variables and a section on the Services web page.
#
#   integrate.sh <padavan-ng/trunk> <tg-ws-proxy binary>
#
# Every edit is anchored on a line that must occur exactly once; if
# upstream moves one, the build stops here instead of producing a
# firmware with a half-wired service.

set -euo pipefail

TRUNK=$(realpath "$1")
BIN=$(realpath "$2")
HERE=$(dirname "$(realpath "$0")")
U="$TRUNK/user"

die() { echo "tgwsproxy: $*" >&2; exit 1; }

[[ -x $BIN ]] || die "binary $BIN not found"
[[ -d $U/rc ]] || die "$TRUNK is not a padavan-ng trunk"

if grep -q APP_TGWSPROXY "$U/shared/cflags.mk"; then
	echo "tgwsproxy: already integrated"
	exit 0
fi

# insert before|after FILE ANCHOR TEXT [EXPECTED_NEXT_LINE]
insert() {
	local mode=$1 file=$2 anchor=$3 text=$4 next=${5-}
	local n
	n=$(grep -cF -- "$anchor" "$file" || true)
	[[ $n == 1 ]] || die "anchor found $n times in ${file#"$TRUNK"/}: $anchor"
	if [[ -n $next ]]; then
		grep -A1 -F -- "$anchor" "$file" | tail -n1 | grep -qxF -- "$next" ||
			die "unexpected line after anchor in ${file#"$TRUNK"/}: $anchor"
	fi
	ANCHOR=$anchor TEXT=$text MODE=$mode awk '
		index($0, ENVIRON["ANCHOR"]) {
			if (ENVIRON["MODE"] == "before") print ENVIRON["TEXT"]
			print
			if (ENVIRON["MODE"] == "after") print ENVIRON["TEXT"]
			next
		}
		{ print }' "$file" > "$file.tgwsp" && mv "$file.tgwsp" "$file"
}

T=$'\t'

# ── package ────────────────────────────────────────────────────────────
mkdir -p "$U/tgwsproxy"
cp "$HERE/Makefile" "$HERE/tgwsproxy.sh" "$U/tgwsproxy/"
cp "$BIN" "$U/tgwsproxy/tg-ws-proxy"
chmod +x "$U/tgwsproxy/tg-ws-proxy" "$U/tgwsproxy/tgwsproxy.sh"

insert after "$U/Makefile" "dir_\$(CONFIG_FIRMWARE_INCLUDE_NFQWS)" \
	"dir_\$(CONFIG_FIRMWARE_INCLUDE_TGWSPROXY)${T}${T}+= tgwsproxy"

cat >> "$U/shared/cflags.mk" <<'EOF'

ifeq ($(CONFIG_FIRMWARE_INCLUDE_TGWSPROXY),y)
CFLAGS += -DAPP_TGWSPROXY
endif
EOF

# ── rc: service control ────────────────────────────────────────────────
cat >> "$U/rc/services.c" <<'EOF'

#if defined(APP_TGWSPROXY)
void stop_tgwsproxy(void){
	eval("/usr/bin/tgwsproxy.sh", "stop");
}

void start_tgwsproxy(void){
	if (nvram_get_int("tgwsp_enable") == 1)
		eval("/usr/bin/tgwsproxy.sh", "start");
}

void restart_tgwsproxy(void){
	stop_tgwsproxy();
	start_tgwsproxy();
}

/* After every firewall rebuild: the rebuild drops our nat rules. */
void reload_tgwsproxy(void){
	eval("/usr/bin/tgwsproxy.sh", "reload");
}
#endif
EOF

insert before "$U/rc/rc.h" "void start_firewall_ex(void);" \
	"void stop_tgwsproxy(void);
void start_tgwsproxy(void);
void restart_tgwsproxy(void);
void reload_tgwsproxy(void);"

insert before "$U/rc/firewall_ex.c" "${T}if (check_if_file_exist(int_iptables_script))" \
	"#if defined(APP_TGWSPROXY)
${T}reload_tgwsproxy();
#endif"

insert after "$U/shared/notify_rc.h" "#define RCN_RESTART_ZAPRET" \
	"#define RCN_RESTART_TGWSPROXY${T}${T}\"restart_tgwsproxy\""

# Closes the zapret block early and reopens it as ours; the original
# closing lines that follow end our block.
insert after "$U/rc/rc.c" "${T}${T}${T}restart_zapret();" \
	"${T}${T}}
#endif
#if defined(APP_TGWSPROXY)
${T}${T}else if (strcmp(entry->d_name, RCN_RESTART_TGWSPROXY) == 0)
${T}${T}{
${T}${T}${T}restart_tgwsproxy();" "${T}${T}}"

# ── nvram defaults ─────────────────────────────────────────────────────
insert before "$U/shared/defaults.c" "#if defined (APP_TOR)" \
	"#if defined (APP_TGWSPROXY)
${T}{ \"tgwsp_enable\", \"0\" },
${T}{ \"tgwsp_ipv6\", \"1\" },
${T}{ \"tgwsp_log\", \"0\" },
${T}{ \"tgwsp_args\", \"\" },
${T}{ \"tgwsp_secret\", \"\" },
#endif"

# ── httpd ──────────────────────────────────────────────────────────────
grep -q "(1ULL << 51)" "$U/httpd/common.h" && die "EVM bit 51 is taken upstream"
insert after "$U/httpd/common.h" "#define EVM_RESTART_IPERF3" \
	"#define EVM_RESTART_TGWSPROXY${T}${T}(1ULL << 51)"
insert after "$U/httpd/common.h" "#define EVT_RESTART_IPERF3" \
	"#define EVT_RESTART_TGWSPROXY${T}${T}1"

insert after "$U/httpd/variables.c" "{\"zapretc.post_script.sh\", \"File\", NULL, EVM_BLOCK_UNSAFE}," \
	"#endif
#if defined(APP_TGWSPROXY)
${T}${T}${T}{\"tgwsp_enable\", \"\", NULL, EVM_RESTART_TGWSPROXY},
${T}${T}${T}{\"tgwsp_ipv6\", \"\", NULL, EVM_RESTART_TGWSPROXY},
${T}${T}${T}{\"tgwsp_log\", \"\", NULL, EVM_RESTART_TGWSPROXY},
${T}${T}${T}{\"tgwsp_args\", \"\", NULL, EVM_RESTART_TGWSPROXY|EVM_BLOCK_UNSAFE}," "#endif"

insert after "$U/httpd/variables.c" "RCN_RESTART_ZAPRET,${T}0}," \
	"#endif
#if defined(APP_TGWSPROXY)
${T}${T}{EVM_RESTART_TGWSPROXY,${T}${T}EVT_RESTART_TGWSPROXY,${T}${T}RCN_RESTART_TGWSPROXY,${T}0}," "#endif"

insert after "$U/httpd/web_ex.c" "${T}int found_app_zapret = 0;" \
	"#endif
#if defined(APP_TGWSPROXY)
${T}int found_app_tgwsp = 1;
#else
${T}int found_app_tgwsp = 0;" "#endif"
insert after "$U/httpd/web_ex.c" '"function found_app_zapret() { return %d;}\n"' \
	"${T}${T}\"function found_app_tgwsp() { return %d;}\\n\""
insert after "$U/httpd/web_ex.c" "${T}${T}found_app_zapret," \
	"${T}${T}found_app_tgwsp,"

# ── web page and strings ───────────────────────────────────────────────
ASP="$U/www/n56u_ribbon_fixed/Advanced_Services_Content.asp"
insert before "$ASP" '<tr id="row_zapret">' "$(cat "$HERE/services.asp.html")"
grep -qF "found_app_zapret() ||" "$ASP" || die "services page: section condition not found"
sed -i 's/found_app_zapret() ||/found_app_zapret() || found_app_tgwsp() ||/' "$ASP"

add_strings() {
	local dict=$1
	shift
	[[ -f $dict ]] || die "missing ${dict#"$TRUNK"/}"
	[[ -z $(tail -c1 "$dict") ]] || echo >> "$dict"
	printf '%s\n' "$@" >> "$dict"
}
add_strings "$U/www/dict/EN.footer" \
	"TgWsp=Transparent Telegram proxy" \
	"TgWsp_desc=Telegram apps on the LAN go through WebSocket (kws*.web.telegram.org) without any proxy settings. Calls (UDP) are not proxied." \
	"TgWsp_ipv6=Block Telegram over IPv6 (apps fall back to proxied IPv4)" \
	"TgWsp_log=Log every connection" \
	"TgWsp_args=Extra tg-ws-proxy options" \
	"TgWsp_link=Manual MTProto link (optional)"
add_strings "$U/www/dict/RU.dict" \
	"TgWsp=Прозрачный прокси Telegram" \
	"TgWsp_desc=Приложения Telegram в локальной сети работают через WebSocket (kws*.web.telegram.org) без настройки прокси на устройствах. Звонки (UDP) не проксируются." \
	"TgWsp_ipv6=Блокировать Telegram по IPv6 (приложения перейдут на проксируемый IPv4)" \
	"TgWsp_log=Логировать каждое соединение" \
	"TgWsp_args=Дополнительные параметры tg-ws-proxy" \
	"TgWsp_link=Ссылка MTProto для ручной настройки (необязательно)"
add_strings "$U/www/dict/UK.dict" \
	"TgWsp=Прозорий проксі Telegram" \
	"TgWsp_desc=Застосунки Telegram у локальній мережі працюють через WebSocket (kws*.web.telegram.org) без налаштування проксі на пристроях. Дзвінки (UDP) не проксуються." \
	"TgWsp_ipv6=Блокувати Telegram через IPv6 (застосунки перейдуть на IPv4 через проксі)" \
	"TgWsp_log=Логувати кожне з'єднання" \
	"TgWsp_args=Додаткові параметри tg-ws-proxy" \
	"TgWsp_link=Посилання MTProto для ручного налаштування (необов'язково)"

echo "tgwsproxy: integrated into ${TRUNK}"
