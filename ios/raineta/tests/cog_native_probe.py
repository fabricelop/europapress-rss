#!/usr/bin/env python3
"""Verify OPERA DBZH COG TIFF is a reproducible direct iPhone data source."""
import datetime as dt,io,json,os,requests,numpy as np
from rasterio.io import MemoryFile
from PIL import Image
now=dt.datetime.now(dt.timezone.utc).replace(second=0,microsecond=0)
now-=dt.timedelta(minutes=now.minute%5)
os.makedirs("cog-proof",exist_ok=True)
session=requests.Session()
found=None
for i in range(20,70,5):
    at=now-dt.timedelta(minutes=i)
    url="https://s3.waw3-1.cloudferro.com/openradar-24h/"+at.strftime("%Y/%m/%d/OPERA/COMP/OPERA@%Y%m%dT%H%M@0@DBZH.tiff")
    r=session.get(url,timeout=24)
    if r.status_code==200 and r.content[:4] in (b"II*\x00",b"MM\x00*"):
        found=(at,url,r.content);break
if not found:raise RuntimeError("No available COG GeoTIFF")
at,url,raw=found
with MemoryFile(raw) as f:
 with f.open() as src:
    valid=src.read(1,masked=True)
    arr=valid.compressed()
    info={
        "time":at.isoformat(),"url":url,"bytes":len(raw),"shape":src.shape,
        "driver":src.driver,"count":src.count,"dtypes":src.dtypes,
        "crs":str(src.crs),"transform":str(src.transform),
        "nodata":src.nodata,"overviews":src.overviews(1),
        "compression":str(src.compression),"block_shapes":src.block_shapes,
        "colorinterp":[str(c) for c in src.colorinterp],
        "min":float(np.min(arr)) if len(arr) else None,
        "max":float(np.max(arr)) if len(arr) else None,
        "valid_frac":float(np.mean(~np.ma.getmaskarray(valid))),
        "wet_frac":float(np.mean(arr>=10)) if len(arr) else None
    }
    print("COG_SUMMARY",json.dumps(info),flush=True)
    # Validate Spain's window: rasterio uses native LAEA projection.
    from rasterio.windows import from_bounds,Window
    from pyproj import Transformer
    p=Transformer.from_crs("EPSG:4326",src.crs,always_xy=True)
    left,bottom=p.transform(-10,35)
    right,top=p.transform(5,45)
    win=from_bounds(min(left,right),min(bottom,top),max(left,right),max(bottom,top),src.transform)
    win=win.round_offsets().round_lengths()
    wet=src.read(1,window=win,masked=True,out_shape=(450,650)).filled(0).astype(np.float32)
    rgba=np.zeros((450,650,4),dtype=np.uint8)
    norm=np.clip((wet-8)/42,0,1)
    rgba[:,:,0]=(75+175*norm).astype(np.uint8)
    rgba[:,:,1]=(195-145*norm).astype(np.uint8)
    rgba[:,:,2]=(250-225*norm).astype(np.uint8)
    rgba[:,:,3]=np.where(wet>=10,235,0).astype(np.uint8)
    Image.fromarray(rgba).save("cog-proof/spain-real-radar.png")
    info["spain_wet_frac"]=float((wet>=10).mean())
json.dump(info,open("cog-proof/info.json","w"),indent=2,ensure_ascii=False)
# Put exactly one real sample into artifacts for Swift decoding experiment.
open("cog-proof/real-composite.tiff","wb").write(raw)
if info["count"]<1 or not info["crs"] or info["shape"]!=(4400,3800):
    raise RuntimeError("Unexpected public COG metadata")
