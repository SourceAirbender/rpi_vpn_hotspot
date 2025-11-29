#!/usr/bin/env python3
# GET /api/status : returns VPN + hotspot + lan + systemd status
# POST /api/run   : {"action": "start"|"stop"} to run the start/stop scripts
# GETs external IPs for LAN + VPN via curl ifconfig.me

import os
import subprocess
import time
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

HOTSPOT_INTERFACE = os.getenv("HOTSPOT_INTERFACE", "wlan0")
LAN_INTERFACE = os.getenv("LAN_INTERFACE", "eth0")
WG_INTERFACE = os.getenv("WG_INTERFACE", "wg0")
HOTSPOT_SERVICE_NAME = os.getenv("HOTSPOT_SERVICE_NAME", "pi-vpn-hotspot.service")
HOSTAPD_SERVICE = os.getenv("HOSTAPD_SERVICE", "hostapd")

WEBUI_PORT = int(os.getenv("WEBUI_PORT", "8090"))
WAN_CACHE_TTL = int(os.getenv("WAN_CACHE_TTL", "60"))

# start/stop scripts
START_SCRIPT = BASE_DIR / "start-hotspot-pizero"
STOP_SCRIPT = BASE_DIR / "stop-hotspot-pizero"

app = Flask(
    __name__,
    static_folder=str(BASE_DIR / "webui_static"),
    static_url_path="",
)

# for curl ifconfig.me
_wan_cache = {
    "ts": 0.0,
    "lan_ip": None,
    "vpn_ip": None,
}

def run_cmd(cmd, timeout=8):
    # run a command and return
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except Exception as e:
        return 1, "", str(e)


def iface_status(iface_name: str):
    # Return status for an interface
    rc, link_out, _ = run_cmd(["ip", "-o", "link", "show", "dev", iface_name])
    if rc != 0:
        return {"name": iface_name, "present": False, "up": False, "ip4": None}

    rc2, addr_out, _ = run_cmd(["ip", "-4", "-o", "addr", "show", "dev", iface_name])
    ip4 = None
    if rc2 == 0 and addr_out:
        parts = addr_out.split()
        try:
            ip4 = parts[3].split("/")[0]  # e.g. 10.x.x.x/24
        except Exception:
            ip4 = None

    up = "state UP" in link_out or "UP" in link_out.split()
    return {"name": iface_name, "present": True, "up": up, "ip4": ip4}


def service_status(unit: str):
    # return ActiveState/SubState/Description for a systemd unit
    status = {"unit": unit, "active_state": None, "sub_state": None, "description": None}
    if not unit:
        return status

    rc, out, _ = run_cmd(
        ["systemctl", "show", unit, "--no-page", "--property=ActiveState,SubState,Description"]
    )
    if rc != 0:
        return status

    for line in out.splitlines():
        if line.startswith("ActiveState="):
            status["active_state"] = line.split("=", 1)[1]
        elif line.startswith("SubState="):
            status["sub_state"] = line.split("=", 1)[1]
        elif line.startswith("Description="):
            status["description"] = line.split("=", 1)[1]
    return status


def get_wan_ips():
    # Get external IPs for LAN_INTERFACE and WG_INTERFACE using curl ifconfig.me
    # Results are cached for WAN_CACHE_TTL seconds to avoid spammin
    now = time.time()
    if now - _wan_cache["ts"] < WAN_CACHE_TTL:
        return _wan_cache["lan_ip"], _wan_cache["vpn_ip"]

    lan_ip = None
    vpn_ip = None

    # LAN
    rc, out, _ = run_cmd(
        ["curl", "-s", "--max-time", "4", "--interface", LAN_INTERFACE, "ifconfig.me"]
    )
    if rc == 0 and out:
        lan_ip = out.strip()

    # VPN
    rc, out, _ = run_cmd(
        ["curl", "-s", "--max-time", "4", "--interface", WG_INTERFACE, "ifconfig.me"]
    )
    if rc == 0 and out:
        vpn_ip = out.strip()

    _wan_cache["ts"] = now
    _wan_cache["lan_ip"] = lan_ip
    _wan_cache["vpn_ip"] = vpn_ip
    return lan_ip, vpn_ip


def get_status():
    # Return overall VPN/hotspot/lan/service status.

    wg = iface_status(WG_INTERFACE)
    hotspot = iface_status(HOTSPOT_INTERFACE)
    svc = service_status(HOTSPOT_SERVICE_NAME)
    hostapd_svc = service_status(HOSTAPD_SERVICE)

    lan_wan_ip, vpn_wan_ip = get_wan_ips()

    vpn_up = wg.get("present") and wg.get("ip4") is not None
    hotspot_up = (
        hotspot.get("present")
        and hotspot.get("ip4") is not None
        and hostapd_svc.get("active_state") == "active"
    )

    # classify overall status
    if not vpn_up and not hotspot_up:
        overall_state = "off"
    elif vpn_up and hotspot_up:
        overall_state = "on"
    else:
        overall_state = "partial"

    return {
        "vpn": {
            "interface": WG_INTERFACE,
            "up": vpn_up,
            "ip4": wg.get("ip4"),
            "wan_ip": vpn_wan_ip,
        },
        "hotspot": {
            "interface": HOTSPOT_INTERFACE,
            "up": hotspot_up,
            "ip4": hotspot.get("ip4"),
            "hostapd": {
                "unit": HOSTAPD_SERVICE,
                "active_state": hostapd_svc.get("active_state"),
                "sub_state": hostapd_svc.get("sub_state"),
            },
        },
        "lan": {
            "interface": LAN_INTERFACE,
            "wan_ip": lan_wan_ip,
        },
        "service": svc,
        "overall_state": overall_state,  # 'on' | 'off' | 'partial'
        "timestamp": time.time(),
    }


def run_script(which: str):
    # Run start or stop script
    if which == "start":
        path = START_SCRIPT
    elif which == "stop":
        path = STOP_SCRIPT
    else:
        raise ValueError("which must be 'start' or 'stop'")

    if not path.exists():
        return 1, "", f"Script not found: {path}"

    return run_cmd([str(path)], timeout=60)


# API route


@app.get("/api/status")
def api_status():
    status = get_status()
    return jsonify(status)


@app.post("/api/run")
def api_run():
    data = request.get_json(silent=True) or {}
    action = data.get("action")
    if action not in {"start", "stop"}:
        return jsonify({"ok": False, "error": "action must be 'start' or 'stop'"}), 400

    rc, out, err = run_script(action)
    status = get_status()
    return jsonify(
        {
            "ok": rc == 0,
            "action": action,
            "exit_code": rc,
            "stdout": out,
            "stderr": err,
            "status": status,
        }
    )


# static / SPA


@app.route("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


if __name__ == "__main__":
    # run on all interfaces so you can hit it from LAN
    app.run(host="0.0.0.0", port=WEBUI_PORT, debug=False)
