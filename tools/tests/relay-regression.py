#!/usr/bin/env python3
"""Regression test for the relay's browser-facing guards.

The relay is the one part of Audisk that listens on a port, so the questions worth
re-asking on every change are: can a page that is not Discord drive it, and can it
be pointed at a host that is not the activity backend.

Run: python3 tools/tests/relay-regression.py

Covers audisk-relay.py. audisk-relay.ps1 is a hand-kept port with the same wire
protocol, so a change here needs the matching change there.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

RELAY = Path(__file__).resolve().parents[1] / "audisk-relay" / "audisk-relay.py"
BASE = "http://127.0.0.1:43210"
PROXY_BODY = json.dumps({
    "url": "https://123.discordsays.com/.proxy/acf/authorize",
    "headers": {},
    "body": "{}",
}).encode()

failures = []


def check(name, condition, detail=""):
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else f'  <- {detail}'}")
    if not condition:
        failures.append(name)


def request(method, path, headers=None, data=None):
    """Returns (status, body, response_headers). An HTTP error is a result, not an exception."""
    req = urllib.request.Request(f"{BASE}{path}", data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, res.read().decode("utf-8", "replace"), dict(res.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)


def main():
    relay = subprocess.Popen([sys.executable, str(RELAY)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            # A relay already running on the port would answer every probe below and the suite
            # would pass without ever testing this checkout. The relay exits non-zero when the
            # bind fails, so a dead child here means the port was taken, not that it is slow.
            if relay.poll() is not None:
                print("127.0.0.1:43210 is already in use; stop the running relay and re-run.")
                return 1
            try:
                request("GET", "/health")
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("relay did not come up on 127.0.0.1:43210")
            return 1

        print("Audisk relay regression")

        status, body, _ = request("GET", "/health")
        check("health probe answers", status == 200 and '"ok":true' in body, f"{status} {body}")

        # The CSRF shape that matters: text/plain is a "simple request", so the browser sends it
        # without a preflight and the relay's Origin check never gets a say.
        status, body, _ = request(
            "POST", "/proxy",
            {"Content-Type": "text/plain", "Origin": "https://evil.example"},
            PROXY_BODY,
        )
        check("unpreflightable POST is refused", status == 403 and "X-Audisk-Relay" in body, f"{status} {body}")

        status, body, _ = request(
            "POST", "/proxy",
            {"Content-Type": "application/json", "Origin": "https://evil.example"},
            PROXY_BODY,
        )
        check("POST without the header is refused whatever the origin", status == 403, f"{status} {body}")

        # With the header the request is allowed to reach the upstream allowlist, which is the
        # check that keeps the relay from being an open proxy.
        status, body, _ = request(
            "POST", "/proxy",
            {"Content-Type": "application/json", "X-Audisk-Relay": "1"},
            json.dumps({"url": "https://evil.example/.proxy/acf/authorize", "headers": {}, "body": "{}"}).encode(),
        )
        check("upstream host allowlist holds", status == 403 and "host not allowed" in body, f"{status} {body}")

        status, body, _ = request(
            "POST", "/proxy",
            {"Content-Type": "application/json", "X-Audisk-Relay": "1"},
            json.dumps({"url": "https://123.discordsays.com/etc/passwd", "headers": {}, "body": "{}"}).encode(),
        )
        check("upstream path allowlist holds", status == 403 and "path not allowed" in body, f"{status} {body}")

        # DNS rebinding: the victim's browser resolves an attacker domain to 127.0.0.1 and the
        # Host header is the only thing that still names the attacker.
        status, body, _ = request("GET", "/health", {"Host": "evil.example"})
        check("rebound Host is refused", status == 403, f"{status} {body}")

        _, _, headers = request("OPTIONS", "/proxy", {"Origin": "https://discord.com"})
        check(
            "preflight allows the required header for Discord",
            headers.get("Access-Control-Allow-Origin") == "https://discord.com"
            and "X-Audisk-Relay" in headers.get("Access-Control-Allow-Headers", ""),
            str(headers),
        )

        _, _, headers = request("OPTIONS", "/proxy", {"Origin": "https://evil.example"})
        check("preflight gives no ACAO to other origins", "Access-Control-Allow-Origin" not in headers, str(headers))

        if failures:
            print(f"\n{len(failures)} check(s) failed: {', '.join(failures)}")
            return 1
        print("\nAll relay checks passed.")
        return 0
    finally:
        relay.terminate()
        relay.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
