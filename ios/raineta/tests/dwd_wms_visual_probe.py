#!/usr/bin/env python3
"""Validate authoritative ICON-EU forecast precipitation as WMS PNG maps."""
import datetime as dt
import json, os, urllib.parse, urllib.request
from xml.etree import ElementTree
from io import BytesIO
import struct,zlib

WMS="https://maps.dwd.de/geoserver/dwd/wms"
params={"service":"WMS","version":"1.1.1","request":"GetMap",
        "layers":"dwd:Icon-eu_reg00625_fd_sl_TOTPREC01H",
        "styles":"","srs":"EPSG:4326","format":"image/png",
        "transparent":"TRUE","width":"850","height":"620"}
now=dt.datetime.now(dt.timezone.utc).replace(minute=0,second=0,microsecond=0)
times=[now+dt.timedelta(hours=h) for h in (2,4)]
boxes={"europe":"-12,42,24,62","iberia":"-10,35,5,45"}
os.makedirs("official-maps",exist_ok=True)
results=[]
for name,bbox in boxes.items():
 for stamp in times:
  args={**params,"bbox":bbox,"time":stamp.isoformat(timespec="seconds").replace("+00:00","Z")}
  url=WMS+"?"+urllib.parse.urlencode(args)
  try:
   request=urllib.request.Request(url,headers={"User-Agent":"RainETA forecast WMS validation/1.0"})
   with urllib.request.urlopen(request,timeout=45) as response:
    data=response.read(12_000_000)
    ctype=response.headers.get("Content-Type","")
   valid=data[:8]==bytes.fromhex("89504e470d0a1a0a") and len(data)>500
   print(json.dumps({"area":name,"time":stamp.isoformat(),"content_type":ctype,
                     "bytes":len(data),"png":valid,
                     "preview":data[:120].decode("utf-8","replace") if not valid else ""}))
   if valid:
    fname=f"official-maps/icon-eu-{name}-{stamp.strftime('%Y%m%d%H')}.png"
    open(fname,"wb").write(data)
    results.append(fname)
  except Exception as exc:print("WMS_ERROR",name,stamp.isoformat(),repr(exc))
print("VALID OFFICIAL MAPS",len(results),results)
if len(results)<2:raise RuntimeError("ICON-EU WMS insufficient to replace current forecast raster")
