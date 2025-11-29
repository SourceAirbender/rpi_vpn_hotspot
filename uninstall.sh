#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root, e.g.: sudo $0" >&2
  exit 1
fi

echo "[*] Repo root: $SCRIPT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

HOTSPOT_SERVICE_NAME="${HOTSPOT_SERVICE_NAME:-pi-vpn-hotspot.service}"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/venv}"

SERVICE_NAME="$HOTSPOT_SERVICE_NAME"
WEBUI_SERVICE_NAME="pi-vpn-hotspot-webui.service"
WATCH_SERVICE_NAME="pi-vpn-hotspot-watch.service"

UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
WEBUI_UNIT_PATH="/etc/systemd/system/$WEBUI_SERVICE_NAME"
WATCH_UNIT_PATH="/etc/systemd/system/$WATCH_SERVICE_NAME"

echo "[*] Stopping and disabling services (if present)..."

for svc in "$WATCH_SERVICE_NAME" "$WEBUI_SERVICE_NAME" "$SERVICE_NAME"; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    echo "    - Disabling & stopping $svc"
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  else
    echo "    - $svc does not appear to be installed."
  fi
done

echo "[*] Removing unit files (if present)..."
for path in "$WATCH_UNIT_PATH" "$WEBUI_UNIT_PATH" "$UNIT_PATH"; do
  if [[ -f "$path" ]]; then
    echo "    - Removing $path"
    rm -f "$path"
  fi
done

echo "[*] Reloading systemd..."
systemctl daemon-reload

if [[ -d "$VENV_DIR" ]]; then
  echo "[*] Removing Python venv at $VENV_DIR ..."
  rm -rf "$VENV_DIR"
else
  echo "[*] No venv directory found at $VENV_DIR."
fi

echo
echo "[✓] Uninstall complete."
echo "    - Systemd units removed: $SERVICE_NAME, $WEBUI_SERVICE_NAME, $WATCH_SERVICE_NAME"
echo "    - venv removed:          $VENV_DIR"
echo
echo "Your scripts (start-hotspot-pizero, stop-hotspot-pizero), .env, and your Termux"
echo "widget setup remain untouched. You can still SSH from Termux and run the scripts"
echo "manually to control the hotspot."
