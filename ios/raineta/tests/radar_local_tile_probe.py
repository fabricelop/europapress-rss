#!/usr/bin/env python3
"""Network diagnostic: verify that the *geographic* radar tile used by the
iPhone app is actually downloadable. This is diagnostic, not a forecast.
"""
import json
import math
import sys
import urllib.request

LAT, LON = 40.4168, -3.7038  # Madrid city centre, only a test coordinate
ZOOM = 7


def tile_at(lat, lon):
    n = 2 ** ZOOM
    wx = (lon + 180) / 360 * n
    wy = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    x, y = int(math.floor(wx)), int(math.floor(wy))
    return x, y, int((wx - x) * 256), int((wy - y) * 256)


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RainETA-radar-test/0.10.1"})
    with urllib.request.urlopen(req, timeout=12) as response:
        return response.read(), response.status


def main():
    payload, status = get("https://api.librewxr.net/public/weather-maps.json")
    assert status == 200
    doc = json.loads(payload)
    host = doc["host"].rstrip("/")
    assert host == "https://api.librewxr.net", f"Unexpected host: {host}"
    last = doc["radar"]["past"][-1]["path"]
    assert last.startswith("/v2/radar/"), last
    x, y, px, py = tile_at(LAT, LON)
    url = f"{host}{last}/256/{ZOOM}/{x}/{y}/2/1_1.png"
    data, status = get(url)
    assert status == 200 and data.startswith(b"\x89PNG\r\n\x1a\n"), (
        f"Radar tile failed: {status}, bytes={len(data)}")
    assert len(data) > 60, "Suspicious empty response"
    print(f"PASS: Madrid z{ZOOM} tile x={x}, y={y}, pixel=({px},{py})")
    print(f"PASS: observed radar PNG returned {len(data)} bytes at {url}")
    print("RainETA samples that specific pixel, not tile center or raw lat/lon.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"RADAR PROVIDER DIAGNOSTIC WARNING: {exc}", file=sys.stderr)
        sys.exit(1)
