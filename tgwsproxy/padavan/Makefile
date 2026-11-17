all:
	@test -x tg-ws-proxy || { echo "tgwsproxy: prebuilt tg-ws-proxy binary is missing" >&2; exit 1; }

clean:

romfs:
	$(ROMFSINST) -p +x tg-ws-proxy /usr/bin/tg-ws-proxy
	$(ROMFSINST) -p +x tgwsproxy.sh /usr/bin/tgwsproxy.sh
