#!/usr/bin/env python3
"""Discover REAL usable open radar / NWP products before implementing iOS nowcast.
No API tokens. Streaming headers and 2MB previews only, no costly bulk downloads.
Emits artifacts/probe.json; errors are reported individually.
"""
import datetime as dt, json, os, requests, sys, time, gzip, io
from urllib.parse import quote
os.makedirs("research-probe",exist_ok=True)
now=dt.datetime.now(dt.timezone.utc).replace(second=0,microsecond=0)
now=now-dt.timedelta(minutes=now.minute%5)
session=requests.Session()
session.headers.update({"User-Agent":"RainETA-iPhone/0.6.0 quality-research (contact via github fabricelop/europapress-rss)"})
results={"utc":now.isoformat(),"sources":{}}
def record(name,**kw):
    results["sources"].setdefault(name,[]).append(kw)
    print(name,json.dumps(kw,ensure_ascii=False),flush=True)
def attempt(name,url,preview=0):
    try:
        resp=session.get(url,stream=True,timeout=(10,18),headers={"Accept":"application/json,*/*"})
        entry={"status":resp.status_code,"type":resp.headers.get("content-type"),"size":resp.headers.get("content-length"),"url":resp.url[:230]}
        if preview:
            buf=b""
            for block in resp.iter_content(65536):
                buf+=block
                if len(buf)>=preview: break
            entry["previewBytes"]=len(buf)
            if "json" in (entry["type"] or ""):
                try:
                    payload=json.loads(buf)
                    entry["keys"]=list(payload)[:12] if isinstance(payload,dict) else None
                    if isinstance(payload,dict):
                        entry["returned"]=len(payload.get("ranges",[])) if "ranges" in payload else len(payload.get("features",[])) if "features" in payload else None
                        entry["sample"]=str(payload)[:4500]
                    else:entry["sample"]=str(payload)[:4000]
                except Exception as e: entry["decodeError"]=str(e)[:300]
            else:entry["headerBytes"]=buf[:32].hex()
        record(name,**entry)
    except Exception as e:record(name,error=repr(e))
    finally:
        try:resp.close()
        except:pass

# Official full HARMONIE-AROME PB/CA public archives.
for domain in ("PB","CA"):
    attempt("AEMET-"+domain,f"https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/{domain}",preview=128*1024)

# Live OPERA composite metadata: 4 separate 5-minute windows.
base="https://api.meteogate.eu/eu-eumetnet-weather-radar/collections/observations/locations/0-20010-0-OPERA"
for product in ("DBZH","RATE"):
    for delta in (20,60):
        st=(now-dt.timedelta(minutes=delta+25)).strftime("%Y-%m-%dT%H:%MZ")
        en=(now-dt.timedelta(minutes=delta)).strftime("%Y-%m-%dT%H:%MZ")
        params={"datetime":f"{st}/{en}","f":"CoverageJSON","standard_name":product,"format":"ODIM"}
        req=requests.Request("GET",base,params=params).prepare()
        attempt("OPERA-"+product,req.url,preview=220*1024)

# Probe selected 3 specific historical composites from 24h S3 to ascertain size.
s3="https://s3.waw3-1.cloudferro.com/openradar-24h"
for mins in (20,25,30):
    at=now-dt.timedelta(minutes=mins)
    path=at.strftime("%Y/%m/%d/OPERA/COMP/OPERA@%Y%m%dT%H%M@0@DBZH.h5")
    url=f"{s3}/{path}"
    try:
        res=session.head(url,timeout=(8,12),allow_redirects=True)
        record("OPERA-S3",timestamp=at.isoformat(),status=res.status_code,size=res.headers.get("Content-Length"),type=res.headers.get("content-type"))
    except Exception as e:record("OPERA-S3",timestamp=at.isoformat(),error=repr(e))
# Try native map-friendly COG/GeoTIFF files without API tokens.
for mins in (25,30):
    at=now-dt.timedelta(minutes=mins)
    for ext in ("tiff","tif","cog.tif"):
        url=f"{s3}/"+at.strftime("%Y/%m/%d/OPERA/COMP/OPERA@%Y%m%dT%H%M@0@DBZH.")+ext
        try:
            res=session.head(url,timeout=(8,12))
            record("OPERA-COG",time=at.isoformat(),extension=ext,
                   status=res.status_code,size=res.headers.get("content-length"),
                   acceptRange=res.headers.get("accept-ranges"))
        except Exception as e:record("OPERA-COG",time=at.isoformat(),extension=ext,error=repr(e))

with open("research-probe/probe.json","w") as out:json.dump(results,out,ensure_ascii=False,indent=2)
