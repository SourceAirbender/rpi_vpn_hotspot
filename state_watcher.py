#!/usr/bin/env python3
# polls VPN + hotspot state and sends a discord notification whenever on/off state changes

import os
import time
import subprocess
from pathlib import Path

from dotenv import load_dotenv
from webhooks import notify_discord

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

HOTSPOT_INTERFACE = os.getenv("HOTSPOT_INTERFACE", "wlan0")
LAN_INTERFACE = os.getenv("LAN_INTERFACE", "eth0")
WG_INTERFACE = os.getenv("WG_INTERFACE", "wg0")
HOTSPOT_SERVICE_NAME = os.getenv("HOTSPOT_SERVICE_NAME", "pi-vpn-hotspot.service")
HOSTAPD_SERVICE = os.getenv("HOSTAPD_SERVICE", "hostapd")
POLL_INTERVAL = int(os.getenv("STATE_POLL_INTERVAL", "10"))


def run_cmd(cmd, timeout=8):
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
    rc, link_out, _ = run_cmd(["ip", "-o", "link", "show", "dev", iface_name])
    if rc != 0:
        return {"name": iface_name, "present": False, "up": False, "ip4": None}

    rc2, addr_out, _ = run_cmd(["ip", "-4", "-o", "addr", "show", "dev", iface_name])
    ip4 = None
    if rc2 == 0 and addr_out:
        parts = addr_out.split()
        try:
            ip4 = parts[3].split("/")[0]
        except Exception:
            ip4 = None

    up = "state UP" in link_out or "UP" in link_out.split()
    return {"name": iface_name, "present": True, "up": up, "ip4": ip4}


def service_status(unit: str):
    status = {"unit": unit, "active_state": None, "sub_state": None}
    if not unit:
        return status

    rc, out, _ = run_cmd(
        ["systemctl", "show", unit, "--no-page", "--property=ActiveState,SubState"]
    )
    if rc != 0:
        return status

    for line in out.splitlines():
        if line.startswith("ActiveState="):
            status["active_state"] = line.split("=", 1)[1]
        elif line.startswith("SubState="):
            status["sub_state"] = line.split("=", 1)[1]
    return status


def get_status():
    wg = iface_status(WG_INTERFACE)
    hotspot = iface_status(HOTSPOT_INTERFACE)
    svc = service_status(HOTSPOT_SERVICE_NAME)
    hostapd_svc = service_status(HOSTAPD_SERVICE)

    vpn_up = wg.get("present") and wg.get("ip4") is not None
    hotspot_up = (
        hotspot.get("present")
        and hotspot.get("ip4") is not None
        and hostapd_svc.get("active_state") == "active"
    )

    if not vpn_up and not hotspot_up:
        overall_state = "off"
    elif vpn_up and hotspot_up:
        overall_state = "on"
    else:
        overall_state = "partial"

    return {
        "vpn": {"up": vpn_up, "ip4": wg.get("ip4")},
        "hotspot": {"up": hotspot_up, "ip4": hotspot.get("ip4")},
        "service": svc,
        "overall_state": overall_state,
    }


def main():
    last_state = None
    while True:
        try:
            status = get_status()
            overall_state = status["overall_state"]

            if last_state is None:
                last_state = overall_state
            elif last_state != overall_state:
                last_state = overall_state
                overall_on = overall_state == "on"
                event = "vpn-hotspot-on" if overall_on else "vpn-hotspot-off"
                svc = status["service"]
                msg = (
                    f"VPN/hotspot is now {overall_state.upper()} "
                    f"(service={svc.get('active_state')}/{svc.get('sub_state')}, "
                    f"wg_ip={status['vpn'].get('ip4')}, "
                    f"hotspot_ip={status['hotspot'].get('ip4')})"
                )
                notify_discord(event, msg)
        except Exception as e:
            print(f"[state_watcher] Error: {e}", flush=True)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
