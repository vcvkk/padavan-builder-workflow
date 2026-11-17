#!/bin/bash
# Upgrade padavan-ng's zapret (nfqws) and ship newer strategy profiles.
#
#   integrate.sh <padavan-ng/trunk>
#
# - nfqws 71.4 -> 72.13 (last zapret1 release: hostfakesplit, fake-tcp-mod,
#   tcp-flags, ip-id, QUIC fragment overlap, ts-fooling fix), with the
#   firmware patch rebased onto it; the source tarball is vendored here.
# - strategy + strategy0..9 replaced by profiles converted from
#   Flowseal/zapret-discord-youtube (see ../tools/flowseal2nfqws.py), each
#   with a Telegram calls block; their names appear in the web UI.
# - zapret-autotest.sh: tries every profile against YouTube/Discord from the
#   router itself and keeps the best one, run from a button on the page.

set -euo pipefail

TRUNK=$(realpath "$1")
HERE=$(dirname "$(realpath "$0")")
STRAT="$HERE/../strategies"
N="$TRUNK/user/nfqws"
VER=72.13
SHA=1647adb42562181e3f787d4e41a3d6c0926d63ca10d14fd174c69d290629b091

die() { echo "zapret: $*" >&2; exit 1; }

[[ -f $N/Makefile ]] || die "$N/Makefile not found"
grep -qx "SRC_VER = $VER" "$N/Makefile" && { echo "zapret: already $VER"; exit 0; }
grep -qx "SRC_VER = 71.4" "$N/Makefile" ||
	die "unexpected upstream zapret version: $(grep '^SRC_VER' "$N/Makefile")"

echo "$SHA  $HERE/zapret-$VER.tar.gz" | sha256sum -c --quiet || die "tarball checksum mismatch"

sed -i "s/^SRC_VER = 71.4\$/SRC_VER = $VER/" "$N/Makefile"
cp "$HERE/zapret-$VER.tar.gz" "$N/zapret-$VER.tar.gz"
cp "$HERE/firmware-specific.patch" "$N/patches/firmware-specific.patch"

# Profiles: copied by zapret.sh into /etc/storage/zapret only where absent.
SHARE="$N/zapretsh-main/zapret/usr/share/zapret"
[[ -d $SHARE/fake ]] || die "$SHARE not found"
cp "$STRAT"/strategy "$STRAT"/strategy[0-9] "$SHARE/"
cp "$STRAT"/fake/*.bin "$SHARE/fake/"

cp "$HERE/zapret-autotest.sh" "$N/zapretsh-main/zapret/usr/bin/zapret-autotest.sh"
ROMFS_LINE='$(ROMFSINST) -p +x $(SRC_NAME_SH)/zapret/usr/bin/zapret.sh /usr/bin/zapret.sh'
grep -qxF "$(printf '\t')$ROMFS_LINE" "$N/Makefile" || die "nfqws Makefile romfs line not found"
sed -i "/zapret\/usr\/bin\/zapret.sh \/usr\/bin\/zapret.sh\$/a\\
\t\$(ROMFSINST) -p +x \$(SRC_NAME_SH)/zapret/usr/bin/zapret-autotest.sh /usr/bin/zapret-autotest.sh" "$N/Makefile"

# Profile names in the strategy selector.
ASP="$TRUNK/user/www/n56u_ribbon_fixed/Advanced_Services_Content.asp"
while IFS=$'\t' read -r file label; do
	if [[ $file == strategy ]]; then
		grep -qF '><#ZapretDefaultProfile#></option>' "$ASP" || die "default profile option not found"
		sed -i "s|><#ZapretDefaultProfile#></option>|><#ZapretDefaultProfile#> ($label)</option>|" "$ASP"
	else
		n=${file#strategy}
		grep -qF "><#ZapretStrategyProfile#> #$n</option>" "$ASP" || die "profile option #$n not found"
		sed -i "s|><#ZapretStrategyProfile#> #$n</option>|><#ZapretStrategyProfile#> #$n: $label</option>|" "$ASP"
	fi
done < "$STRAT/labels.tsv"

# Autotest buttons above the log selector (anchor: the row holding ZapretLog).
grep -c '<th><#ZapretLog#>:</th>' "$ASP" | grep -qx 1 || die "ZapretLog row not found"
SNIP="$HERE/autotest.asp.html" awk '
	BEGIN { while ((getline l < ENVIRON["SNIP"]) > 0) snip = snip l "\n" }
	NR > 1 && index($0, "<th><#ZapretLog#>:</th>") { printf "%s", snip }
	NR > 1 { print prev }
	{ prev = $0 }
	END { print prev }' "$ASP" > "$ASP.tmp" && mv "$ASP.tmp" "$ASP"

add_strings() {
	local dict=$1
	shift
	[[ -z $(tail -c1 "$dict") ]] || echo >> "$dict"
	printf '%s\n' "$@" >> "$dict"
}
D="$TRUNK/user/www/dict"
add_strings "$D/EN.footer" "ZapretAutotest=Pick a profile for this ISP" \
	"ZapretAutotest_run=Run (3-4 min)" "ZapretAutotest_status=Result"
add_strings "$D/RU.dict" "ZapretAutotest=Подобрать профиль под провайдера" \
	"ZapretAutotest_run=Подобрать (3-4 мин)" "ZapretAutotest_status=Результат"
add_strings "$D/UK.dict" "ZapretAutotest=Підібрати профіль під провайдера" \
	"ZapretAutotest_run=Підібрати (3-4 хв)" "ZapretAutotest_status=Результат"

echo "zapret: nfqws $VER and $(wc -l < "$STRAT/labels.tsv") profiles integrated"
