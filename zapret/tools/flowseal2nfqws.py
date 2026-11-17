#!/usr/bin/env python3
"""Convert Flowseal/zapret-discord-youtube winws strategies (.bat) into
nfqws strategy files for zapret.sh on Padavan.

    flowseal2nfqws.py <zapret-discord-youtube dir> <out dir>

winws is nfqws for Windows, so the desync arguments carry over unchanged.
What differs is the plumbing around them:

- --wf-* (WinDivert port filters) are dropped: zapret.sh builds its iptables
  rules from the --filter-tcp/--filter-udp ports of the profiles themselves.
- Flowseal's general/user host lists become <HOSTLIST> (zapret.sh's
  user.list + auto.list + exclude.list); QUIC profiles get <HOSTLIST_NOAUTO>
  like the stock strategies. list-google.txt is inlined with
  --hostlist-domains so the file does not have to live in /etc/storage.
- Profiles keyed on ipset-all.txt (a placeholder unless the user fills it)
  and the optional game filter are dropped; ipset-exclude.txt only lists
  private ranges, which never reach the WAN.
- Fake payloads point at /usr/share/zapret/fake.
- Every strategy gets a Telegram calls block (STUN on the relay ports).
"""

import pathlib
import re
import shlex
import sys

FAKE = "/usr/share/zapret/fake/"

# (output file, Flowseal .bat, label shown in the web UI)
PROFILES = [
    # Operators after the profile name are where community reports say it
    # worked (Flowseal issues/discussions, 2025-2026); a hint, not a promise.
    ("strategy", "general.bat", "general"),
    ("strategy0", "general (ALT).bat", "ALT: fake+fakedsplit"),
    ("strategy1", "general (ALT2).bat", "ALT2: multisplit 652 — Дом.ру, Ростелеком"),
    ("strategy2", "general (ALT3).bat", "ALT3: hostfakesplit ya.ru — Билайн"),
    ("strategy3", "general (ALT4).bat", "ALT4: fake+multisplit badseq"),
    ("strategy4", "general (ALT6).bat", "ALT6: multisplit 681 — МТС"),
    ("strategy5", "general (ALT7).bat", "ALT7: multisplit sniext"),
    ("strategy6", "general (ALT9).bat", "ALT9: hostfakesplit ozon.ru"),
    ("strategy7", "general (ALT11).bat", "ALT11: fake+multisplit 664"),
    ("strategy8", "general (FAKE TLS AUTO ALT2).bat", "FAKE TLS AUTO ALT2"),
    ("strategy9", "general (SIMPLE FAKE).bat", "SIMPLE FAKE — Ростелеком, Билайн"),
]

TELEGRAM_CALLS = f"""
### Telegram calls: STUN to Telegram relays (UDP 1400; 590-1400 and
### 3478-3481 seen on some ISPs). P2P calls use random high ports: either set
### Telegram > Privacy > Calls > Peer-to-peer to "Nobody", or uncomment the
### wide range below (costs CPU on busy UDP traffic such as torrents).
--new --filter-udp=590-1400,3478-3481
--filter-l7=stun --dpi-desync=fake --dpi-desync-fake-stun={FAKE}stun.bin
--dpi-desync-repeats=6 --dpi-desync-cutoff=n3
#--new --filter-udp=20000-65535
#--filter-l7=stun --dpi-desync=fake --dpi-desync-fake-stun={FAKE}stun.bin
#--dpi-desync-repeats=6 --dpi-desync-cutoff=n3
"""


def winws_args(bat: str) -> list[str]:
    text = bat.replace("\r", "")
    start = text.index("winws.exe")
    body = text[start + len("winws.exe") :]
    body = re.sub(r"\^\n", " ", body)  # cmd line continuations
    body = body.split("\n\n")[0]
    body = body.replace("^!", "!")
    body = body.strip().lstrip('"').strip()
    return shlex.split(body, posix=True)


def google_domains(root: pathlib.Path) -> str:
    lines = (root / "lists" / "list-google.txt").read_text().split()
    return ",".join(d for d in lines if d and not d.startswith("#"))


def convert(root: pathlib.Path, bat: str, label: str) -> str:
    args = winws_args((root / bat).read_text(encoding="utf-8", errors="replace"))
    profiles: list[list[str]] = [[]]
    for a in args:
        if a == "--new":
            profiles.append([])
        else:
            profiles[-1].append(a)

    out = [
        f"### {label}",
        f"### converted from Flowseal/zapret-discord-youtube: {bat}",
        "### All arguments: https://github.com/bol-van/zapret/blob/master/docs/readme.md",
    ]
    google = google_domains(root)
    used_bins: set[str] = set()
    for prof in profiles:
        prof = [a for a in prof if not a.startswith("--wf-")]
        if any("%GameFilter" in a for a in prof):
            continue
        if any(a.startswith("--ipset=") and "ipset-all" in a for a in prof):
            continue
        kept: list[str] = []
        lists = False
        quic = any(a.startswith("--filter-udp=") for a in prof)
        for a in prof:
            if a.startswith("--wf-"):
                continue
            key, _, val = a.partition("=")
            if key in ("--hostlist", "--hostlist-exclude", "--ipset-exclude"):
                if "list-google" in val:
                    kept.append(f"--hostlist-domains={google}")
                elif "list-general" in val or "list-exclude" in val:
                    lists = True
                continue
            if "%BIN%" in val:
                name = val.replace("%BIN%", "")
                used_bins.add(name)
                a = f"{key}={FAKE}{name}"
            if "%" in a:
                raise SystemExit(f"{bat}: unhandled variable in {a}")
            kept.append(a)
        if not kept:
            continue
        if lists:
            kept.append("<HOSTLIST_NOAUTO>" if quic else "<HOSTLIST>")
        out.append("")
        out.append(("--new " if len(out) > 4 else "") + " ".join(kept))
    out.append(TELEGRAM_CALLS.rstrip())
    convert.bins |= used_bins | {"stun.bin"}
    return "\n".join(out) + "\n"


convert.bins = set()


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    dest = pathlib.Path(sys.argv[2])
    (dest / "fake").mkdir(parents=True, exist_ok=True)
    labels = []
    for name, bat, label in PROFILES:
        (dest / name).write_text(convert(root, bat, label), encoding="utf-8")
        labels.append(f"{name}\t{label}")
    (dest / "labels.tsv").write_text("\n".join(labels) + "\n", encoding="utf-8")
    for b in sorted(convert.bins):
        src = root / "bin" / b
        if not src.exists():
            raise SystemExit(f"missing payload {b}")
        (dest / "fake" / b).write_bytes(src.read_bytes())
    print(f"{len(PROFILES)} strategies, payloads: {' '.join(sorted(convert.bins))}")


if __name__ == "__main__":
    main()
