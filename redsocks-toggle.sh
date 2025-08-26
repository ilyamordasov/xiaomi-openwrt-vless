#!/usr/bin/env sh
set -e

# ===== .env (локальные секреты) =====
# Пример /root/redsocks.env:
# SERVER_HOST=your.server
# SERVER_PORT=your.port
# SOCKS_USER=login
# SOCKS_PASS=password
# LAN_IF=br-lan
[ -f /root/redsocks.env ] && { set -a; . /root/redsocks.env; set +a; }

# ===== ДЕФОЛТЫ (без секретов) =====
SERVER_HOST="${SERVER_HOST:-example.com}"
SERVER_PORT="${SERVER_PORT:-443}"
SOCKS_USER="${SOCKS_USER:-user}"
SOCKS_PASS="${SOCKS_PASS:-password}"
LAN_IF="${LAN_IF:-}"              # пусто = авто
LOCAL_PORT="${LOCAL_PORT:-12345}"

DNS_HIJACK="${DNS_HIJACK:-1}"     # 1 = перехватывать DNS:53 на роутер (через UCI)
FILTER_AAAA="${FILTER_AAAA:-0}"   # 1 = скрыть AAAA в dnsmasq
DOT_853_REDIRECT="${DOT_853_REDIRECT:-1}"  # 1 = заворачивать DoT:853
SERVER_BYPASS="${SERVER_BYPASS:-1}"        # 1 = не трогать трафик на SOCKS-сервер

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

pm_install(){
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@" >/dev/null || apk add "$@"
  elif command -v opkg >/dev/null 2>&1; then
    opkg update; opkg install "$@" || true
  else
    echo "No apk/opkg found"; exit 1
  fi
}

detect_lan_if(){
  [ -n "$LAN_IF" ] && { echo "$LAN_IF"; return; }
  IF="$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/ {print $2; exit}')"
  echo "${IF:-br-lan}"
}

detect_lan_cidr(){
  IF="$1"
  CIDR="$(ip -o -4 addr show dev "$IF" 2>/dev/null | awk '{print $4; exit}')"
  if [ -n "$CIDR" ]; then
    if command -v ipcalc.sh >/dev/null 2>&1; then
      eval "$(ipcalc.sh "$CIDR" | sed -n 's/^\(NETWORK\|PREFIX\)=/\1=/p')"
      echo "${NETWORK}/${PREFIX}"
    else
      echo "$CIDR" | awk -F'[./]' '{printf "%s.%s.%s.0/%s",$1,$2,$3,$5}'
    fi
  else
    IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
    NM="$(uci -q get network.lan.netmask || echo 255.255.255.0)"
    if command -v ipcalc.sh >/dev/null 2>&1; then
      eval "$(ipcalc.sh "$IP" "$NM" | sed -n 's/^\(NETWORK\|PREFIX\)=/\1=/p')"
      echo "${NETWORK}/${PREFIX}"
    else
      echo "$IP" | awk -F. '{printf "%s.%s.%s.0/24",$1,$2,$3}'
    fi
  fi
}

write_redsocks_conf(){
cat >/etc/redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:local7";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = $LOCAL_PORT;
    ip = $SERVER_HOST;
    port = $SERVER_PORT;
    type = socks5;
    login = "$SOCKS_USER";
    password = "$SOCKS_PASS";
}

dnstc {
    local_ip = 127.0.0.1;
    local_port = 5300;
}
EOF
}

start_redsocks(){
  if [ -x /etc/init.d/redsocks ]; then
    /etc/init.d/redsocks enable || true
    /etc/init.d/redsocks restart || true
  else
    pkill -f 'redsocks -c /etc/redsocks.conf' 2>/dev/null || true
    nohup redsocks -c /etc/redsocks.conf >/var/log/redsocks.nohup 2>&1 &
  fi
}

resolve_server_ip(){
  echo "$SERVER_HOST" | grep -Eq '^[0-9]+\.' && { echo "$SERVER_HOST"; return; }
  command -v nslookup >/dev/null 2>&1 || { echo ""; return; }
  nslookup "$SERVER_HOST" 2>/dev/null | awk '/^Address [0-9]+: /{ip=$3} /^Address: /{ip=$2} END{print ip}'
}

apply_nft(){
  LAN_CIDR="$1"; SERVIP="$2"

  nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
  nft list chain ip nat PREROUTING >/dev/null 2>&1 || nft add chain ip nat PREROUTING '{ type nat hook prerouting priority dstnat ; policy accept ; }'
  nft list chain ip nat REDSOCKS  >/dev/null 2>&1 || nft add chain ip nat REDSOCKS

  # чистим наши помеченные правила
  for h in $(nft -a list chain ip nat PREROUTING 2>/dev/null | awk '/redsocks_bypass|redsocks_jump|redsocks_bypass_server/ {print $NF}'); do nft delete rule ip nat PREROUTING handle "$h" 2>/dev/null || true; done
  for h in $(nft -a list chain ip nat REDSOCKS   2>/dev/null | awk '{print $NF}'); do nft delete rule ip nat REDSOCKS   handle "$h" 2>/dev/null || true; done

  nft add rule ip nat PREROUTING ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } return comment "redsocks_bypass"
  [ "$SERVER_BYPASS" = "1" ] && [ -n "$SERVIP" ] && nft add rule ip nat PREROUTING ip daddr "$SERVIP" return comment "redsocks_bypass_server" || true
  nft add rule ip nat PREROUTING ip saddr "$LAN_CIDR" ip protocol tcp counter jump REDSOCKS comment "redsocks_jump"

  nft add rule ip nat REDSOCKS tcp dport 80  dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_80"
  nft add rule ip nat REDSOCKS tcp dport 443 dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_443"
  [ "$DOT_853_REDIRECT" = "1" ] && nft add rule ip nat REDSOCKS tcp dport 853 dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_dot853" || true

  # Если нет UCI, поставим rule для блокировки QUIC прямо в nft (inet/mangle)
  if ! command -v uci >/dev/null 2>&1; then
    nft list table inet mangle >/dev/null 2>&1 || nft add table inet mangle
    nft list chain inet mangle prerouting >/dev/null 2>&1 || nft add chain inet mangle prerouting '{ type filter hook prerouting priority -150 ; }'
    # удалим старый наш drop и добавим новый
    for h in $(nft -a list chain inet mangle prerouting 2>/dev/null | awk '/redsocks_drop_quic/ {print $NF}'); do nft delete rule inet mangle prerouting handle "$h" 2>/dev/null || true; done
    nft add rule inet mangle prerouting udp dport 443 drop comment "redsocks_drop_quic"
  fi
}

persist_include_fw4(){
  LAN_CIDR="$1"; SERVIP="$2"; DOT="$3"
  [ ! -d /etc ] && return 0
cat >/etc/redsocks.nft.sh <<'EOS'
#!/bin/sh
set -e
LAN_CIDR="__LAN_CIDR__"
LOCAL_PORT="__LOCAL_PORT__"
SERVER_IP="__SERVER_IP__"
DOT="__DOT__"

nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
nft list chain ip nat PREROUTING >/dev/null 2>&1 || nft add chain ip nat PREROUTING '{ type nat hook prerouting priority dstnat ; policy accept ; }'
nft list chain ip nat REDSOCKS  >/dev/null 2>&1 || nft add chain ip nat REDSOCKS

for h in $(nft -a list chain ip nat PREROUTING 2>/dev/null | awk '/redsocks_bypass|redsocks_jump|redsocks_bypass_server/ {print $NF}'); do nft delete rule ip nat PREROUTING handle "$h" 2>/dev/null || true; done
for h in $(nft -a list chain ip nat REDSOCKS   2>/dev/null | awk '{print $NF}'); do nft delete rule ip nat REDSOCKS   handle "$h" 2>/dev/null || true; done

nft add rule ip nat PREROUTING ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } return comment "redsocks_bypass"
[ -n "$SERVER_IP" ] && nft add rule ip nat PREROUTING ip daddr "$SERVER_IP" return comment "redsocks_bypass_server" || true
nft add rule ip nat PREROUTING ip saddr "$LAN_CIDR" ip protocol tcp counter jump REDSOCKS comment "redsocks_jump"

nft add rule ip nat REDSOCKS tcp dport 80  dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_80"
nft add rule ip nat REDSOCKS tcp dport 443 dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_443"
[ "$DOT" = "1" ] && nft add rule ip nat REDSOCKS tcp dport 853 dnat to 127.0.0.1:$LOCAL_PORT comment "redsocks_redirect_dot853" || true
EOS
  sed -i "s|__LAN_CIDR__|$LAN_CIDR|g" /etc/redsocks.nft.sh
  sed -i "s|__LOCAL_PORT__|$LOCAL_PORT|g" /etc/redsocks.nft.sh
  sed -i "s|__SERVER_IP__|$SERVIP|g" /etc/redsocks.nft.sh
  sed -i "s|__DOT__|$DOT|g" /etc/redsocks.nft.sh
  chmod +x /etc/redsocks.nft.sh

  if command -v uci >/dev/null 2>&1; then
    if ! uci show firewall 2>/dev/null | grep -q "path='/etc/redsocks.nft.sh'"; then
      uci add firewall include >/dev/null
      uci set firewall.@include[-1].type='script'
      uci set firewall.@include[-1].path='/etc/redsocks.nft.sh'
      uci set firewall.@include[-1].reload='1'
      uci commit firewall
    fi
  else
    # Без UCI — попытаемся автозапуск через rc.local
    if [ -f /etc/rc.local ]; then
      grep -q '/etc/redsocks.nft.sh' /etc/rc.local || sed -i "\#^exit 0#i /etc/redsocks.nft.sh" /etc/rc.local
    fi
  fi
}

add_quic_dns_rules(){
  if command -v uci >/dev/null 2>&1; then
    # QUIC drop
    if ! uci show firewall 2>/dev/null | grep -q "Block-QUIC-UDP443"; then
      uci add firewall rule >/dev/null
      uci set firewall.@rule[-1].name='Block-QUIC-UDP443'
      uci set firewall.@rule[-1].src='lan'
      uci set firewall.@rule[-1].dest='wan'
      uci set firewall.@rule[-1].proto='udp'
      uci set firewall.@rule[-1].dest_port='443'
      uci set firewall.@rule[-1].target='REJECT'
    fi
    # DNS hijack
    if [ "$DNS_HIJACK" = "1" ] && ! uci show firewall 2>/dev/null | grep -q "DNS-Hijack-LAN"; then
      LANIP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
      uci add firewall redirect >/dev/null
      uci set firewall.@redirect[-1].name='DNS-Hijack-LAN'
      uci set firewall.@redirect[-1].src='lan'
      uci set firewall.@redirect[-1].src_dport='53'
      uci set firewall.@redirect[-1].proto='tcp udp'
      uci set firewall.@redirect[-1].dest_ip="$LANIP"
      uci set firewall.@redirect[-1].dest_port='53'
      uci set firewall.@redirect[-1].target='DNAT'
    fi
    uci commit firewall
    # AAAA filter
    if [ "$FILTER_AAAA" = "1" ]; then
      uci set dhcp.@dnsmasq[0].filter_aaaa='1'
      uci commit dhcp
      /etc/init.d/dnsmasq restart || true
    fi
  fi
}

remove_all(){
  # nft: убрать наши правила
  for h in $(nft -a list chain ip nat PREROUTING 2>/dev/null | awk '/redsocks_bypass|redsocks_jump|redsocks_bypass_server|jump REDSOCKS/ {print $NF}'); do nft delete rule ip nat PREROUTING handle "$h" 2>/dev/null || true; done
  nft flush chain ip nat REDSOCKS 2>/dev/null || true
  nft delete chain ip nat REDSOCKS 2>/dev/null || true

  # UCI: убрать include/QUIC/DNS
  if command -v uci >/dev/null 2>&1; then
    for sec in $(uci show firewall 2>/dev/null | awk -F. '/@include\[[0-9]+\]\.path=..\/etc\/redsocks\.nft\.sh/ {print $1"."$2}'); do uci delete "$sec" || true; done
    for sec in $(uci show firewall 2>/dev/null | awk -F= '/Block-QUIC-UDP443|DNS-Hijack-LAN/ {print $1}' | sed 's/\.name.*//'); do uci delete "$sec" || true; done
    uci commit firewall || true
    /etc/init.d/firewall restart || true
  fi

  # dnsmasq: вернуть AAAA если включали
  if [ "$FILTER_AAAA" = "1" ] && command -v uci >/dev/null 2>&1; then
    uci -q del dhcp.@dnsmasq[0].filter_aaaa || true
    uci commit dhcp || true
    /etc/init.d/dnsmasq restart || true
  fi

  # остановить redsocks (конфиг НЕ трогаем)
  pkill -f 'redsocks -c /etc/redsocks.conf' 2>/dev/null || true
  [ -x /etc/init.d/redsocks ] && /etc/init.d/redsocks stop || true
}

deep_clean(){
  # убить redsocks
  pkill -f 'redsocks -c /etc/redsocks.conf' 2>/dev/null || true
  [ -x /etc/init.d/redsocks ] && /etc/init.d/redsocks stop || true

  # nft
  for h in $(nft -a list chain ip nat PREROUTING 2>/dev/null | awk '/jump REDSOCKS|redsocks_/ {print $NF}'); do nft delete rule ip nat PREROUTING handle "$h" 2>/dev/null || true; done
  nft flush chain ip nat REDSOCKS 2>/dev/null || true
  nft delete chain ip nat REDSOCKS 2>/dev/null || true

  # iptables legacy хвосты (если когда-то ставили)
  for IF in br-lan br0 lan lan1 lan2; do
    iptables -t nat    -D PREROUTING -i "$IF" -p tcp -j REDSOCKS 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$IF" -p udp --dport 443 -j REJECT 2>/dev/null || true
  done
  iptables -t nat -F REDSOCKS 2>/dev/null || true
  iptables -t nat -X REDSOCKS 2>/dev/null || true

  # UCI хвосты
  if command -v uci >/dev/null 2>&1; then
    for sec in $(uci show firewall 2>/dev/null | awk -F. '/@include\[[0-9]+\]\.path=..\/etc\/redsocks\.nft\.sh/ {print $1"."$2}'); do uci delete "$sec" || true; done
    for sec in $(uci show firewall 2>/dev/null | awk -F. '/@include\[[0-9]+\]\.path=..\/etc\/firewall\.redsocks/ {print $1"."$2}'); do uci delete "$sec" || true; done
    for sec in $(uci show firewall 2>/dev/null | awk -F= '/Block-QUIC-UDP443|DNS-Hijack-LAN|Redsocks-HTTP-80|Redsocks-HTTPS-443/ {print $1}' | sed 's/\.name.*//'); do uci delete "$sec" || true; done
    uci commit firewall || true
    /etc/init.d/firewall restart || true
    # dnsmasq
    uci -q del dhcp.@dnsmasq[0].filter_aaaa || true
    uci commit dhcp || true
    /etc/init.d/dnsmasq restart || true
  fi

  # скрипты-хвосты
  rm -f /etc/redsocks.nft.sh /usr/local/sbin/redsocks-* /etc/firewall.redsocks 2>/dev/null || true
}

do_add(){
  echo "[+] installing deps (nftables, redsocks)"
  pm_install nftables redsocks || true
  need nft

  [ -f /etc/redsocks.conf ] || write_redsocks_conf
  start_redsocks

  IFACE="$(detect_lan_if)"
  CIDR="$(detect_lan_cidr "$IFACE")"
  SERV_IP=""
  [ "$SERVER_BYPASS" = "1" ] && SERV_IP="$(resolve_server_ip || true)"

  echo "[i] LAN_IF=$IFACE  LAN_CIDR=$CIDR  SERVER_IP=${SERV_IP:-n/a}"

  apply_nft "$CIDR" "$SERV_IP"
  persist_include_fw4 "$CIDR" "$SERV_IP" "$DOT_853_REDIRECT"
  add_quic_dns_rules

  # перезапустим firewall если есть UCI
  command -v uci >/dev/null 2>&1 && /etc/init.d/firewall restart || true

  echo "=== STATUS ==="
  ss -lntp 2>/dev/null | grep ":$LOCAL_PORT" || true
  nft list chain ip nat PREROUTING || true
  nft list chain ip nat REDSOCKS   || true
  echo "[✓] add: done"
}

do_remove(){ remove_all; echo "[✓] remove: done"; }

# -------- entry --------
ACTION="$1"
[ -z "$ACTION" ] && { printf "Action? [a]dd / [r]emove / [c]lean : "; read ACTION; }
case "$ACTION" in
  a|A|add)    do_add ;;
  r|R|remove) do_remove ;;
  c|C|clean)  deep_clean ;;
  *) echo "Use: add | remove | clean" ; exit 2 ;;
esac
