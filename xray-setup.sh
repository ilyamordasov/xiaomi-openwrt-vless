#!/bin/sh
set -eu
umask 077

# ========= Safe config (no secrets here) =========
XRAY_VERSION="${XRAY_VERSION:-v25.8.3}"
XRAY_URL_BASE="https://github.com/XTLS/Xray-core/releases/download"
XRAY_DIR="/usr/bin"
XRAY_BIN="$XRAY_DIR/xray"
XRAY_ETC="/etc/xray"
XRAY_ENV="$XRAY_ETC/.env"
XRAY_JSON="$XRAY_ETC/config.json"
XRAY_SYSTEMD="/etc/systemd/system/xray.service"
XRAY_INIT="/etc/init.d/xray"
XRAY_LOG_DIR="/var/log/xray"
TMP_DIR="/tmp/xray_install"

msg(){ echo "[xray-install] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ========= Load .env (required) =========
if [ ! -f "$XRAY_ENV" ]; then
  echo "[xray-install] ERROR: $XRAY_ENV not found. Create it and rerun."
  exit 1
fi
# shellcheck disable=SC1090
. "$XRAY_ENV"

# minimal validation (do NOT print values)
require() { eval "v=\${$1:-}"; [ -n "$v" ] || { echo "[xray-install] ERROR: missing $1 in $XRAY_ENV"; exit 2; }; }
for k in XRAY_SOCKS_PORT XRAY_SS_PORT XRAY_SOCKS_USER XRAY_SOCKS_PASS XRAY_SS_METHOD XRAY_SS_PASSWORD \
         XRAY_VLESS_ADDRESS XRAY_VLESS_PORT XRAY_VLESS_ID XRAY_REALITY_FINGERPRINT XRAY_REALITY_PUBLIC_KEY \
         XRAY_REALITY_SNI XRAY_REALITY_SHORTID XRAY_DNS_RU XRAY_DNS_PROXY XRAY_LOGLEVEL XRAY_ACCESS_LOG XRAY_ERROR_LOG
do require "$k"; done

# ========= Detect pkg manager =========
PKG=""
have apt-get && PKG="apt"
have apk && PKG="apk"
have opkg && PKG="opkg"

msg "Installing deps (wget unzip ca-certs) ..."
case "$PKG" in
  apt)  sudo apt-get update -y; sudo apt-get install -y wget unzip ca-certificates ufw || true ;;
  apk)  apk add --no-cache wget unzip ca-certificates ;;
  opkg) opkg update || true; opkg install wget unzip ca-bundle ca-certificates >/dev/null 2>&1 || opkg install unzip ;;
  *)    msg "WARN: unknown pkg manager; ensure wget/unzip/ca-certs present." ;;
esac

install -d "$XRAY_ETC" "$XRAY_DIR" "$XRAY_LOG_DIR"
: >"$XRAY_LOG_DIR/access.log"
: >"$XRAY_LOG_DIR/error.log"
chmod 600 "$XRAY_ENV" "$XRAY_LOG_DIR"/access.log "$XRAY_LOG_DIR"/error.log

# ========= Download Xray (arch auto) =========
ARCH="$(uname -m || true)"
case "$ARCH" in
  x86_64|amd64) XRAY_ZIP="Xray-linux-64.zip" ;;
  aarch64)      XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
  armv7l)       XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
  mipsel|mipsle)XRAY_ZIP="Xray-linux-mipsle.zip" ;;
  mips|mips64|mips64el) XRAY_ZIP="Xray-linux-mips64le.zip" ;;
  *)            XRAY_ZIP="Xray-linux-64.zip"; msg "WARN: unknown arch '$ARCH', using ${XRAY_ZIP}" ;;
esac

mkdir -p "$TMP_DIR"
cd "$TMP_DIR"
XRAY_URL="$XRAY_URL_BASE/$XRAY_VERSION/$XRAY_ZIP"
msg "Downloading $XRAY_URL"
wget --no-check-certificate -O "$XRAY_ZIP" "$XRAY_URL"
unzip -o "$XRAY_ZIP" xray geoip.dat geosite.dat >/dev/null
install -m 0755 xray "$XRAY_BIN"
install -m 0644 geoip.dat "$XRAY_ETC/geoip.dat" 2>/dev/null || true
install -m 0644 geosite.dat "$XRAY_ETC/geosite.dat" 2>/dev/null || true

# ========= Service (systemd or OpenWrt procd) =========
if have systemctl; then
  msg "Installing systemd unit ..."
  cat >"$XRAY_SYSTEMD" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $XRAY_JSON
Restart=always
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
else
  msg "Installing procd init.d ..."
  cat >"$XRAY_INIT" <<'INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG="/usr/bin/xray"
CONF="/etc/xray/config.json"
start_service() {
  [ -x "$PROG" ] || exit 1
  [ -f "$CONF" ] || exit 1
  procd_open_instance
  procd_set_param command "$PROG" run -confdir /etc/xray
  procd_set_param respawn 3600 1 1
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
INIT
  chmod +x "$XRAY_INIT"
fi

# ========= Enable IPv6 (for SS too) =========
if have sysctl; then
  msg "Enabling IPv6 (runtime + persistent)"
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 || true
  if [ -d /etc/sysctl.d ]; then
    cat >/etc/sysctl.d/99-xray-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF
    sysctl --system >/dev/null 2>&1 || true
  fi
fi

# ========= UFW (if present) open ports; do not print secrets =========
if have ufw; then
  msg "UFW: allowing SOCKS/SS ports"
  sudo ufw allow "${XRAY_SOCKS_PORT}/tcp" || true
  sudo ufw allow "${XRAY_SOCKS_PORT}/udp" || true
  sudo ufw allow "${XRAY_SS_PORT}/tcp" || true
  sudo ufw allow "${XRAY_SS_PORT}/udp" || true
  if ! sudo ufw status | grep -qi active; then echo "y" | sudo ufw enable || true; fi
  sudo ufw reload || true
  sudo ufw status || true
fi

# ========= Start service =========
msg "Starting Xray ..."
if have systemctl; then
  sudo systemctl enable xray || true
  sudo systemctl restart xray
else
  /etc/init.d/xray enable || true
  /etc/init.d/xray restart || true
fi

msg "Done."
echo "Config: $XRAY_JSON   Env: $XRAY_ENV   Logs: $XRAY_LOG_DIR"
echo "Ports opened: SOCKS=${XRAY_SOCKS_PORT}, SS=${XRAY_SS_PORT}"
