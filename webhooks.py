#!/usr/bin/env python3
# send Discord notifications using DISCORD_WEBHOOK_URL in .env


import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "").strip()


def notify_discord(event: str, message: str) -> None:
  #event is a short tag like 'vpn-hotspot-on', 'vpn-hotspot-off'
  if not DISCORD_WEBHOOK_URL:
    return

  payload = {
    "content": f"[{event}] {message}",
    "username": "Pi Hotspot",
  }
  try:
    requests.post(DISCORD_WEBHOOK_URL, json=payload, timeout=10)
  except Exception as e:
    # log to stdout so its in journald/systemd logs
    print(f"[webhooks] Failed to send Discord webhook: {e}", flush=True)


if __name__ == "__main__":
  # CLI usage like:
  #   ./venv/bin/python webhooks.py vpn-hotspot-on "VPN + hotspot enabled"
  event = sys.argv[1] if len(sys.argv) > 1 else "generic"
  msg = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""
  notify_discord(event, msg or f"Event {event}")

