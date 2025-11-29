#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root, e.g.: sudo $0" >&2
  exit 1
fi

echo "[*] Repo root: $SCRIPT_DIR"

# --------------------------------------------------
# .env exists?
# --------------------------------------------------
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    echo "[!] .env did not exist. I copied .env.example -> .env."
    echo "    Please edit .env with your real values and re-run install.sh."
    exit 1
  else
    echo "[!] Missing .env and .env.example - create .env first." >&2
    exit 1
  fi
fi

set -a
# shellcheck disable=SC1091
. "$SCRIPT_DIR/.env"
set +a

PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-wlan0}"
HOTSPOT_STATIC_CIDR="${HOTSPOT_STATIC_CIDR:-192.168.50.1/24}"
LAN_INTERFACE="${LAN_INTERFACE:-eth0}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONFIG_SOURCE_PATH="${WG_CONFIG_SOURCE_PATH:-}"
HOSTAPD_SERVICE="${HOSTAPD_SERVICE:-hostapd}"
DNSMASQ_SERVICE="${DNSMASQ_SERVICE:-dnsmasq}"
HOTSPOT_SERVICE_NAME="${HOTSPOT_SERVICE_NAME:-pi-vpn-hotspot.service}"
PING_HOST="${PING_HOST:-1.1.1.1}"
VPN_HEALTHCHECK_HOST="${VPN_HEALTHCHECK_HOST:-}"
EXPECTED_LAN_WAN_IP="${EXPECTED_LAN_WAN_IP:-}"
EXPECTED_VPN_WAN_IP="${EXPECTED_VPN_WAN_IP:-}"
WEBUI_PORT="${WEBUI_PORT:-8090}"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/venv}"

# globals used by check_wan_ips()
CHECK_LAN_WAN_IP=""
CHECK_VPN_WAN_IP=""

echo "[*] Using configuration:"
echo "    PROJECT_ROOT          = $PROJECT_ROOT"
echo "    HOTSPOT_INTERFACE     = $HOTSPOT_INTERFACE"
echo "    HOTSPOT_STATIC_CIDR   = $HOTSPOT_STATIC_CIDR"
echo "    LAN_INTERFACE         = $LAN_INTERFACE"
echo "    WG_INTERFACE          = $WG_INTERFACE"
if [[ -n "$WG_CONFIG_SOURCE_PATH" ]]; then
  echo "    WG_CONFIG_SOURCE_PATH = $WG_CONFIG_SOURCE_PATH"
fi
echo "    HOTSPOT_SERVICE_NAME  = $HOTSPOT_SERVICE_NAME"
echo "    HOSTAPD_SERVICE       = $HOSTAPD_SERVICE"
echo "    DNSMASQ_SERVICE       = $DNSMASQ_SERVICE"
echo "    PING_HOST             = $PING_HOST"
if [[ -n "$VPN_HEALTHCHECK_HOST" ]]; then
  echo "    VPN_HEALTHCHECK_HOST  = $VPN_HEALTHCHECK_HOST"
fi
if [[ -n "$EXPECTED_LAN_WAN_IP" ]]; then
  echo "    EXPECTED_LAN_WAN_IP   = $EXPECTED_LAN_WAN_IP"
fi
if [[ -n "$EXPECTED_VPN_WAN_IP" ]]; then
  echo "    EXPECTED_VPN_WAN_IP   = $EXPECTED_VPN_WAN_IP"
fi
echo "    WEBUI_PORT            = $WEBUI_PORT"
echo "    VENV_DIR              = $VENV_DIR"

need() {
  local bin="$1"
  local pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[!] Missing dependency: $bin" >&2
    echo "    Install it via apt, e.g.: sudo apt update && sudo apt install -y $pkg" >&2
    exit 1
  fi
}

echo "[*] Checking system dependencies..."
need python3    python3
need pip3       python3-pip
need systemctl  systemd
need ip         iproute2
need iptables   iptables
need ping       iputils-ping
need curl       curl
need wg-quick   wireguard-tools
need wg         wireguard-tools
need hostapd    hostapd
need dnsmasq    dnsmasq

# --------------------------------------------------
# Wi-Fi interfaces
# --------------------------------------------------
echo "[*] Detecting Wi-Fi interfaces..."
wifi_ifaces=()
while IFS= read -r iface; do
  wifi_ifaces+=("$iface")
done < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+' || true)

wifi_count=${#wifi_ifaces[@]}
echo "    Detected Wi-Fi interfaces: ${wifi_ifaces[*]:-(none)}"

if (( wifi_count == 0 )); then
  echo "[!] No wlan* interfaces detected. This project expects at least one Wi-Fi interface." >&2
  exit 1
fi

if [[ ! " ${wifi_ifaces[*]} " =~ " ${HOTSPOT_INTERFACE} " ]]; then
  echo "[!] HOTSPOT_INTERFACE=$HOTSPOT_INTERFACE is not among detected Wi-Fi interfaces: ${wifi_ifaces[*]}" >&2
  echo "    Check your .env or your hardware configuration." >&2
  exit 1
fi

# --------------------------------------------------
# LAN interface
# --------------------------------------------------
if ip -o link show dev "$LAN_INTERFACE" >/dev/null 2>&1; then
  echo "[*] Using LAN_INTERFACE=$LAN_INTERFACE for base external IP checks."
else
  echo "[!] Warning: LAN_INTERFACE=$LAN_INTERFACE not found. External IP checks over LAN may fail." >&2
fi


# WireGuard config sync
# --------------------------------------------------
DEST_CONF="/etc/wireguard/${WG_INTERFACE}.conf"

if [[ -n "$WG_CONFIG_SOURCE_PATH" ]]; then
  # allow relative path
  if [[ "$WG_CONFIG_SOURCE_PATH" != /* ]]; then
    WG_CONFIG_SOURCE_PATH="$SCRIPT_DIR/$WG_CONFIG_SOURCE_PATH"
  fi

  if [[ ! -f "$WG_CONFIG_SOURCE_PATH" ]]; then
    echo "[!] WG_CONFIG_SOURCE_PATH is set but file not found: $WG_CONFIG_SOURCE_PATH" >&2
  else
    echo "[*] Syncing WireGuard config:"
    echo "    source: $WG_CONFIG_SOURCE_PATH"
    echo "    dest:   $DEST_CONF"
    mkdir -p /etc/wireguard

    if [[ -f "$DEST_CONF" ]]; then
      backup="${DEST_CONF}.bak.$(date +%s)"
      echo "    [!] Existing dest found; backing up to $backup"
      cp "$DEST_CONF" "$backup"
    fi

    install -m 600 -o root -g root "$WG_CONFIG_SOURCE_PATH" "$DEST_CONF"
  fi
fi

if [[ -f "$DEST_CONF" ]]; then
  echo "[*] Using WireGuard config at: $DEST_CONF"
else
  echo "[!] Warning: WireGuard config not found at $DEST_CONF" >&2
  echo "    - wg-quick@${WG_INTERFACE} expects its config here." >&2
  echo "    - Set WG_CONFIG_SOURCE_PATH in .env if you want install.sh to copy it for you." >&2
fi

# --------------------------------------------------
# Create/check venv
# --------------------------------------------------
if [[ ! -d "$VENV_DIR" ]]; then
  echo "[*] Creating Python venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
else
  echo "[*] Using existing venv at $VENV_DIR"
fi

echo "[*] Installing Python requirements (if any)..."
"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
if [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
  "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"
else
  echo "[!] requirements.txt not found; skipping pip install from file." >&2
fi

# --------------------------------------------------
# check req vars
# --------------------------------------------------
REQUIRED_VARS=(HOTSPOT_INTERFACE HOTSPOT_STATIC_CIDR WG_INTERFACE HOSTAPD_SERVICE DNSMASQ_SERVICE HOTSPOT_SERVICE_NAME LAN_INTERFACE)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    MISSING+=("$var")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  echo "[!] The following required vars are empty or unset: ${MISSING[*]}" >&2
  echo "    Please update .env and re-run." >&2
  exit 1
fi

# --------------------------------------------------
# base ping check (before VPN)
# --------------------------------------------------
echo "[*] Pinging PING_HOST=$PING_HOST ..."
if ping -c1 -W1 "$PING_HOST" >/dev/null 2>&1; then
  echo "    [OK] $PING_HOST reachable."
else
  echo "    [!] Warning: $PING_HOST not reachable; continuing anyway." >&2
fi

# --------------------------------------------------
# check hotspot scripts
# --------------------------------------------------
START_SCRIPT="$SCRIPT_DIR/start-hotspot-pizero"
STOP_SCRIPT="$SCRIPT_DIR/stop-hotspot-pizero"

if [[ ! -f "$START_SCRIPT" ]]; then
  echo "[!] start-hotspot-pizero script not found at: $START_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$STOP_SCRIPT" ]]; then
  echo "[!] stop-hotspot-pizero script not found at: $STOP_SCRIPT" >&2
  exit 1
fi

echo "[*] Ensuring hotspot scripts are executable..."
chmod +x "$START_SCRIPT" "$STOP_SCRIPT"

# --------------------------------------------------
# post IP checks
# --------------------------------------------------
check_wan_ips() {
  local lan_if="$LAN_INTERFACE"
  local vpn_if="$WG_INTERFACE"
  local lan_ip="" vpn_ip=""

  echo "[*] Checking external IPs using curl ifconfig.me ..."

  if lan_ip=$(curl -s --max-time 6 --interface "$lan_if" ifconfig.me 2>/dev/null); then
    echo "    LAN ($lan_if) WAN IP: $lan_ip"
  else
    echo "    [!] Failed to get WAN IP over $lan_if" >&2
  fi

  if vpn_ip=$(curl -s --max-time 6 --interface "$vpn_if" ifconfig.me 2>/dev/null); then
    echo "    VPN ($vpn_if) WAN IP: $vpn_ip"
  else
    echo "    [!] Failed to get WAN IP over $vpn_if" >&2
  fi

  CHECK_LAN_WAN_IP="$lan_ip"
  CHECK_VPN_WAN_IP="$vpn_ip"

  if [[ -n "$lan_ip" && -n "$vpn_ip" ]]; then
    if [[ "$lan_ip" == "$vpn_ip" ]]; then
      echo "    [!] Warning: LAN and VPN external IPs are identical; VPN routing may not be applied." >&2
    else
      echo "    [OK] LAN and VPN external IPs differ."
    fi
  fi

  if [[ -n "$EXPECTED_LAN_WAN_IP" && -n "$lan_ip" && "$lan_ip" != "$EXPECTED_LAN_WAN_IP" ]]; then
    echo "    [!] Warning: LAN WAN IP $lan_ip does not match EXPECTED_LAN_WAN_IP=$EXPECTED_LAN_WAN_IP" >&2
  fi
  if [[ -n "$EXPECTED_VPN_WAN_IP" && -n "$vpn_ip" && "$vpn_ip" != "$EXPECTED_VPN_WAN_IP" ]]; then
    echo "    [!] Warning: VPN WAN IP $vpn_ip does not match EXPECTED_VPN_WAN_IP=$EXPECTED_VPN_WAN_IP" >&2
  fi
}

# --------------------------------------------------
# systemd units
#
# control should still be done from Termux on Android
# --------------------------------------------------
SERVICE_NAME="$HOTSPOT_SERVICE_NAME"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"

echo "[*] Writing $UNIT_PATH ..."
cat >"$UNIT_PATH" <<EOF
[Unit]
Description=WireGuard-backed Wi-Fi hotspot on ${HOTSPOT_INTERFACE}
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$START_SCRIPT
ExecStop=$STOP_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# wbUI service
WEBUI_SERVICE_NAME="pi-vpn-hotspot-webui.service"
WEBUI_UNIT_PATH="/etc/systemd/system/$WEBUI_SERVICE_NAME"

echo "[*] Writing $WEBUI_UNIT_PATH ..."
cat >"$WEBUI_UNIT_PATH" <<EOF
[Unit]
Description=Pi VPN Hotspot Web UI (Flask)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_DIR/bin/python $SCRIPT_DIR/webui_server.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=PATH=$VENV_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# discord watcher service
WATCH_SERVICE_NAME="pi-vpn-hotspot-watch.service"
WATCH_UNIT_PATH="/etc/systemd/system/$WATCH_SERVICE_NAME"

echo "[*] Writing $WATCH_UNIT_PATH ..."
cat >"$WATCH_UNIT_PATH" <<EOF
[Unit]
Description=Pi VPN Hotspot Discord watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_DIR/bin/python $SCRIPT_DIR/state_watcher.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=PATH=$VENV_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------------------
# reload systemd & enable units
# --------------------------------------------------
echo "[*] Reloading systemd..."
systemctl daemon-reload

echo "[*] Enabling and starting core services..."
systemctl enable --now "$SERVICE_NAME" || echo "[!] Warning: failed to start $SERVICE_NAME (check logs)." >&2
systemctl enable --now "$WEBUI_SERVICE_NAME"
systemctl enable --now "$WATCH_SERVICE_NAME"

# --------------------------------------------------
# health checks
# --------------------------------------------------
echo "[*] Performing post-start external IP checks (LAN vs VPN)..."
check_wan_ips

if [[ -n "$VPN_HEALTHCHECK_HOST" && -n "$CHECK_VPN_WAN_IP" ]]; then
  echo "[*] Pinging VPN_HEALTHCHECK_HOST=$VPN_HEALTHCHECK_HOST ..."
  if ping -c1 -W1 "$VPN_HEALTHCHECK_HOST" >/dev/null 2>&1; then
    echo "    [OK] VPN_HEALTHCHECK_HOST reachable: $VPN_HEALTHCHECK_HOST"
  else
    echo "    [!] Warning: VPN_HEALTHCHECK_HOST not reachable: $VPN_HEALTHCHECK_HOST" >&2
  fi
elif [[ -n "$VPN_HEALTHCHECK_HOST" ]]; then
  echo "[*] Skipping VPN_HEALTHCHECK_HOST ping because VPN external IP could not be determined." >&2
fi

echo
echo "[✓] Install complete."
echo "    - Hotspot service:    systemctl status $SERVICE_NAME"
echo "    - Web UI service:     systemctl status $WEBUI_SERVICE_NAME"
echo "                           Browser: http://<Pi_LAN_IP>:$WEBUI_PORT/"
echo "    - Discord watcher:    systemctl status $WATCH_SERVICE_NAME"
echo
echo "Primary control remains via Termux on your Android phone:"
echo "  - Termux widget -> SSH into the Pi -> run ./start-hotspot-pizero or ./stop-hotspot-pizero"
echo
echo "WireGuard (PiVPN) interface:"
echo "    Interface name:       $WG_INTERFACE"
echo "    Config location:      $DEST_CONF"
if [[ -n "$WG_CONFIG_SOURCE_PATH" ]]; then
  echo "    Source-of-truth:      $WG_CONFIG_SOURCE_PATH (copied on install)"
fi
