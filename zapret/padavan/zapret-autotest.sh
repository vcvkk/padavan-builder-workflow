#!/bin/sh
# Pick the zapret profile that works best on this ISP, on this router.
#
#   zapret-autotest.sh          run in the background, log to $LOG
#   zapret-autotest.sh run      run in the foreground
#   zapret-autotest.sh status   show the last result
#
# For every profile (default, #0..#9) and once without zapret, fetch a few
# YouTube/Discord resources over TLS with the openssl CLI. A target passes
# when the response completes, or when more than FREEZE_LIMIT bytes arrive
# before the timeout: TSPU blocks either kill the handshake or freeze the
# connection after ~16-20 KB, so a stall below that line is a block. The
# best-scoring profile is saved to nvram and zapret restarted with it.
#
# Idea and targets after Flowseal/zapret-discord-youtube "Run Tests" and
# hyperion-cs/dpi-checkers (tcp-16-20).

LOG=/tmp/zapret-autotest.log
LOCK=/var/run/zapret-autotest.pid
WORK=/tmp/zapret-autotest
TIMEOUT=${TIMEOUT:-8}
FREEZE_LIMIT=65536
PROFILES="${PROFILES:-x - 0 1 2 3 4 5 6 7 8 9}"
STRATEGY_DIR=${STRATEGY_DIR:-/etc/storage/zapret}
ZAPRET=${ZAPRET:-/usr/bin/zapret.sh}
OPENSSL=${OPENSSL:-openssl}

# host path [port]
TARGETS="${TARGETS:-www.youtube.com /
i.ytimg.com /vi/dQw4w9WgXcQ/maxresdefault.jpg
redirector.googlevideo.com /report_mapping
discord.com /
cdn.discordapp.com /embed/avatars/0.png
gateway.discord.gg /}"

log() { echo "$*"; logger -t zapret-autotest "$*" 2>/dev/null; }

label() {
	case "$1" in
	x) echo "без zapret" ;;
	-) f="$STRATEGY_DIR/strategy" ;;
	*) f="$STRATEGY_DIR/strategy$1" ;;
	esac
	[ "$1" = x ] && return
	l="$(sed -n '1s/^### *//p' "$f" 2>/dev/null)"
	[ "$1" = - ] && echo "по умолчанию${l:+ ($l)}" || echo "#$1${l:+ $l}"
}

# Probe every target in parallel; print the number that passed.
probe_all() {
	rm -rf "$WORK" && mkdir -p "$WORK"
	n=0
	pids=""
	echo "$TARGETS" | while read -r host path port; do
		[ -n "$host" ] || continue
		n=$((n + 1))
		printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\nAccept: */*\r\nConnection: close\r\n\r\n' \
			"$path" "$host" > "$WORK/$n.req"
		# -quiet implies -ign_eof: the request file ending does not close
		# the connection, the server does after the response.
		"$OPENSSL" s_client -connect "$host:${port:-443}" -servername "$host" -quiet \
			< "$WORK/$n.req" > "$WORK/$n.out" 2>/dev/null &
		echo "$! $n $host" >> "$WORK/pids"
	done

	t=0
	while [ $t -lt "$TIMEOUT" ]; do
		alive=0
		while read -r pid n host; do
			kill -0 "$pid" 2>/dev/null && alive=1
		done < "$WORK/pids"
		[ $alive = 0 ] && break
		sleep 1
		t=$((t + 1))
	done

	pass=0
	while read -r pid n host; do
		bytes=$(wc -c < "$WORK/$n.out")
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null
			# Still running at the timeout: fine only past the freeze zone.
			[ "$bytes" -ge $FREEZE_LIMIT ] && ok=1 || ok=0
		else
			head -n 1 "$WORK/$n.out" | grep -q '^HTTP/1\.[01] ' && ok=1 || ok=0
		fi
		[ $ok = 1 ] && pass=$((pass + 1))
		echo "$host:$ok:$bytes" >> "$WORK/detail"
	done < "$WORK/pids"
	echo "$pass"
}

use_profile() {
	if [ "$1" = x ]; then
		"$ZAPRET" stop >/dev/null 2>&1
	else
		[ "$1" = - ] && nvram set zapret_strategy="" || nvram set zapret_strategy="$1"
		"$ZAPRET" restart >/dev/null 2>&1
	fi
	sleep 2
}

run() {
	command -v "$OPENSSL" >/dev/null 2>&1 || { log "openssl не найден"; exit 1; }
	total=$(echo "$TARGETS" | grep -c .)
	was_enabled="$(nvram get zapret_enable)"
	was_profile="$(nvram get zapret_strategy)"
	best=""
	best_score=-1
	log "Автоподбор профиля zapret: $total проверок на профиль, таймаут ${TIMEOUT}с"
	for p in $PROFILES; do
		[ "$p" = x ] || [ "$p" = - ] || [ -s "$STRATEGY_DIR/strategy$p" ] || continue
		use_profile "$p"
		score=$(probe_all)
		failed=$(grep ':0:' "$WORK/detail" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
		log "$(printf '%2s/%s  %s%s' "$score" "$total" "$(label "$p")" "${failed:+  — не прошли: $failed}")"
		if [ "$p" != x ] && [ "$score" -gt "$best_score" ]; then
			best=$p
			best_score=$score
		fi
		[ "$p" = x ] && baseline=$score
	done
	rm -rf "$WORK"

	if [ -z "$best" ]; then
		log "Не найдено ни одного профиля"
		nvram set zapret_strategy="$was_profile"
		[ "$was_enabled" = 1 ] && "$ZAPRET" restart >/dev/null 2>&1
		exit 1
	fi
	[ "$best" = - ] && nvram set zapret_strategy="" || nvram set zapret_strategy="$best"
	nvram set zapret_enable=1
	nvram commit
	"$ZAPRET" restart >/dev/null 2>&1
	log "Выбран профиль: $(label "$best") — $best_score/$total (без zapret: ${baseline:-?}/$total). Включён и сохранён."
	[ "$best_score" -lt "$total" ] &&
		log "Не всё прошло: попробуйте позже ещё раз или выберите профиль вручную в Администрирование → Сервисы."
}

case "$1" in
run)
	run
	;;
status)
	cat "$LOG" 2>/dev/null || echo "Автоподбор ещё не запускался"
	;;
*)
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
		echo "Автоподбор уже идёт, ход: $0 status"
		exit 0
	fi
	( run > "$LOG" 2>&1; rm -f "$LOCK" ) </dev/null >/dev/null 2>&1 &
	echo $! > "$LOCK"
	echo "Автоподбор запущен (~3-4 минуты). Ход и результат: $0 status"
	;;
esac
