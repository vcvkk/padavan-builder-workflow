# Sourced by the "Run custom pre-build script" step, from the repository root.

if [[ $CONFIG_FIRMWARE_INCLUDE_TGWSPROXY == y ]]; then
  chmod +x tgwsproxy/bin/tg-ws-proxy
  bash tgwsproxy/padavan/integrate.sh padavan-ng/trunk tgwsproxy/bin/tg-ws-proxy || exit 1
fi

if [[ $CONFIG_FIRMWARE_INCLUDE_NFQWS == y ]]; then
  bash zapret/padavan/integrate.sh padavan-ng/trunk || exit 1
fi
