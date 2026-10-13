#!/usr/bin/env python3
"""Probe WeatherAPI's documented free, keyless *native map tiles* at real coordinates."""
import datetime as dt
import json
import math
import os
import urllib.error
import urllib.request

now=dt.datetime.now(dt.timezone.utc).replace(minute=0,second=0,microsecond=0)
stamps=[now+dt.timedelta(hours=1),now+dt.timedelta(hours=3)]
lat,lon=52.1,5.1
def tile(z):
    n=2**z
    x=int((lon+180)/360*n)
    y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n)
    return x,y
os.makedirs("tile-probes",exist_ok=True)
found=[]
for stamp in stamps:
    stamp_text=stamp.strftime("%Y%m%d%H")
    for z in (4,5,6,7,8,9,10,11,12):
        x,y=tile(z)
        url=f"https://weathermaps.weatherapi.com/precip/tiles/{stamp_text}/{z}/{x}/{y}.png"
        try:
            request=urllib.request.Request(url,headers={"User-Agent":"RainETA-iPhone-WeatherMap-Validation/1.0"})
            with urllib.request.urlopen(request,timeout=14) as resp:
                body=resp.read()
                content_type=resp.headers.get("Content-Type","")
                status=resp.status
            valid=body[:8]==bytes.fromhex("89504e470d0a1a0a") and len(body)>80
            print(json.dumps({"time":stamp_text,"z":z,"x":x,"y":y,"status":status,
                              "content_type":content_type,"bytes":len(body),"png":valid}))
            if valid:
                path=f"tile-probes/precip-{stamp_text}-z{z}.png"
                open(path,"wb").write(body)
                found.append({"time":stamp_text,"z":z,"file":path,"bytes":len(body)})
        except Exception as exc:
            print(json.dumps({"time":stamp_text,"z":z,"error":str(exc)}))
with open("tile-probes/probe.json","w") as f:json.dump(found,f,indent=2)
print("valid tiles:",len(found), "zoom levels:",sorted(set(d["z"] for d in found)))
if len(found)<2 or max(p["z"] for p in found)<5:
    raise RuntimeError("Forecast tile provider not viable at required map scale")
