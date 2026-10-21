#!/usr/bin/env python3
"""Inspect AEMET HARMONIE-AROME PB real georeferenced precipitation TIFF frames.

Reads streaming official tar.gz and stops after representative 1-hour fields.
No server / no account; research only, not an operational iPhone feed.
"""
import io,json,os,tarfile,re
import requests,numpy as np
import rasterio
from rasterio.io import MemoryFile
from PIL import Image
os.makedirs("harmonie-science",exist_ok=True)
url="https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB"
s=requests.Session()
r=s.get(url,stream=True,timeout=(15,45))
r.raise_for_status()
records=[]
examples=[]
names=[]
with tarfile.open(fileobj=r.raw,mode="r|gz") as arc:
 for member in arc:
  if not member.isfile(): continue
  names.append(member.name)
  if not re.search(r"_61_1HH\.tif$",member.name):continue
  with arc.extractfile(member) as mf:data=mf.read()
  with MemoryFile(data) as source:
   with source.open() as ds:
    img=ds.read(1,masked=True).astype(np.float32)
    valid=img.compressed()
    rec={"name":member.name,"bytes":len(data),"width":ds.width,"height":ds.height,
         "bands":ds.count,"dtype":ds.dtypes,"colorinterp":[str(x) for x in ds.colorinterp],
         "maskflags":[[str(z) for z in y] for y in ds.mask_flag_enums],
         "colorTableCount": len(ds.colormap(1)) if ds.colorinterp[0].name=="palette" else 0,
         "crs":str(ds.crs),"bounds":[round(x,3) for x in ds.bounds],
         "nodata":ds.nodata,"validFraction":round(float(np.mean(~np.ma.getmaskarray(img))),4),
         "min":float(np.min(valid)) if len(valid) else None,
         "max":float(np.max(valid)) if len(valid) else None,
         "nonzero":float(np.mean(valid>0.1)) if len(valid) else None}
    records.append(rec)
    print("HARMONIE_FRAME",json.dumps(rec),flush=True)
    if len(examples)<5:
     a=np.maximum(0,np.asarray(img.filled(0),dtype=np.float32))
     a=np.where(a<0.1,0,a)
     rgba=np.zeros((*a.shape,4),dtype=np.uint8)
     norm=np.clip(np.log1p(a)/np.log1p(15),0,1)
     rgba[:,:,0]=(80+175*norm).astype(np.uint8)
     rgba[:,:,1]=(160-120*norm).astype(np.uint8)
     rgba[:,:,2]=(255-215*norm).astype(np.uint8)
     rgba[:,:,3]=(norm*235).astype(np.uint8)
     Image.fromarray(rgba,"RGBA").save(f"harmonie-science/precip-{len(examples):02}.png")
     examples.append(member.name)
  if len(records)>=10:break
r.close()
result={"frames":records,"firstFileNames":names[:25],"previewCount":len(examples),
        "allPrecipTimeTags":[x["name"] for x in records]}
json.dump(result,open("harmonie-science/inspection.json","w"),indent=2)
print("SUMMARY",json.dumps({"frames":len(records),"first_file_types":names[:25],
                           "usablePrecipFrames":len(examples)}),flush=True)
if len(records)<4:raise RuntimeError("Insufficient georeferenced hourly HARMONIE precipitation fields")
