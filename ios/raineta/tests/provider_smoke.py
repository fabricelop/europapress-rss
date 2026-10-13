#!/usr/bin/env python3
"""Public provider smoke test: three georeferenced 15-minute forecasts."""
import json
import time
import urllib.error
import urllib.parse
import urllib.request

args = {
    "latitude": "40.4168,40.6368,40.1968",
    "longitude": "-3.7038,-3.5038,-3.9038",
    "minutely_15": "precipitation",
    "forecast_minutely_15": "25",
    "timezone": "GMT",
    "timeformat": "unixtime",
    "cell_selection": "nearest",
}
url = "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(args)
last_error = None
for attempt in range(3):
    try:
        with urllib.request.urlopen(urllib.request.Request(
            url, headers={"User-Agent": "RainETA/0.4 integration-check"}), timeout=25
        ) as response:
            body = json.load(response)
        assert isinstance(body, list) and len(body) == 3, "Wrong multi-location schema"
        baseline = None
        for i, place in enumerate(body):
            rows = place["minutely_15"]
            times, rain = rows["time"], rows["precipitation"]
            assert len(times) == len(rain) and len(times) >= 17
            assert all(isinstance(t, (int, float)) for t in times)
            assert all(t2 > t1 for t1, t2 in zip(times, times[1:]))
            assert all((v is None or (isinstance(v, (int, float)) and v >= 0)) for v in rain)
            if baseline is None:
                baseline = times
            else:
                assert baseline == times, "Provider timestamps do not align across coordinates"
            print(f"Location {i+1}: {len(times)} real model timesteps; non-null {sum(v is not None for v in rain)}")
        print("OPEN METEO MULTI-LOCATION PROVIDER SMOKE: PASS")
        break
    except (urllib.error.URLError, AssertionError, KeyError, ValueError) as exc:
        last_error = exc
        print(f"Attempt {attempt+1} failed: {exc}")
        time.sleep(2 ** attempt)
else:
    raise RuntimeError(f"Model provider integration unavailable: {last_error}")
