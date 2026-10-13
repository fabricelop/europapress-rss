#!/usr/bin/env python3
"""RainETA OPERA 5-min backtest. Uses REAL following radar frames, not samples.

Compare one 3-frame optical-flow advection against the persistence baseline
for +5 and +15 minutes over predetermined cities. This is a research experiment,
NOT an operational nowcast or an iOS shipping approval.
"""
import datetime as dt
import io
import json
import math
import os
import re
from collections import defaultdict

import cv2
import h5py
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import requests
from pyproj import Proj

os.makedirs("radar-science", exist_ok=True)
base="https://api.meteogate.eu/eu-eumetnet-weather-radar/collections/observations/locations/0-20010-0-OPERA"
now=dt.datetime.now(dt.timezone.utc).replace(second=0,microsecond=0)
params={
    "datetime":f"{(now-dt.timedelta(minutes=120)).strftime('%Y-%m-%dT%H:%MZ')}/{(now-dt.timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%MZ')}",
    "f":"CoverageJSON","standard_name":"DBZH","format":"ODIM"
}
session=requests.Session()
session.headers.update({"User-Agent":"RainETA 0.6.0 optical-flow validation personal project"})
# Direct CC BY 4.0 S3 objects avoid anonymous MeteoGate rate limits.
# Never require an API token or exhaust an API quota for scientific validation.
candidates=[]
for lag in range(20,100,5):
    at=now-dt.timedelta(minutes=lag)
    at=at-dt.timedelta(minutes=at.minute%5)
    path=at.strftime("%Y/%m/%d/OPERA/COMP/OPERA@%Y%m%dT%H%M@0@DBZH.h5")
    url="https://s3.waw3-1.cloudferro.com/openradar-24h/"+path
    try:
        response=session.head(url,timeout=15)
        if response.status_code==200:
            candidates.append((at,url))
    except requests.RequestException:
        pass
candidates=sorted(candidates)
if len(candidates)<8:
    raise RuntimeError(f"Need >=8 usable S3 composite frames, found {len(candidates)}")
# Most recent uninterrupted sequence; no interpolation of missing radar scans.
streak=[candidates[0]]
for item in candidates[1:]:
    if (item[0]-streak[-1][0]).total_seconds()==300:streak.append(item)
    else:streak=[item]
    if len(streak)>=11: break
if len(streak)<8:
    raise RuntimeError(f"No contiguous 5-minute set of 8+ scans (max streak {len(streak)})")
streak=streak[-11:]
times=[x[0] for x in streak]
files=[x[1] for x in streak]
print("DATA",len(files),times[0].isoformat(),times[-1].isoformat(),flush=True)

# Fixed sampling of Spanish and neighboring European locations avoids cherry picking.
cities=[
("Madrid",40.4168,-3.7038),("Bilbao",43.26,-2.93),
("Barcelona",41.39,2.17),("Valencia",39.47,-0.38),
("Santiago",42.88,-8.54),("Sevilla",37.39,-5.99),
("Lisboa",38.72,-9.14),("Burdeos",44.84,-0.58),
("París",48.86,2.35),("Londres",51.51,-0.13),
("Ámsterdam",52.37,4.9),("Hamburgo",53.55,10),
("Milán",45.46,9.19),("Viena",48.21,16.37),
("Praga",50.08,14.44),("Estocolmo",59.33,18.06)
]
projection=Proj("+proj=laea +lat_0=55 +lon_0=10 +x_0=1950000 +y_0=-2100000 +units=m +ellps=WGS84")
size=320
radius=size//2
crop={}
for name,lat,lon in cities:
    x,y=projection(lon,lat)
    c=round(x/1000)
    r=round(-y/1000)
    if radius<=r<4400-radius and radius<=c<3800-radius:
       crop[name]=(r,c,lat,lon)
print("LOCATIONS",len(crop),flush=True)
radars={name:[] for name in crop}
nodata={}
for url,time in zip(files,times):
    req=session.get(url,timeout=28)
    req.raise_for_status()
    with h5py.File(io.BytesIO(req.content),"r") as src:
        ds=src["dataset1/data1/data"]
        attrs=src["dataset1/data1/what"].attrs
        if ds.shape!=(4400,3800) or str(attrs["quantity"]) not in ("DBZH","b'DBZH'"):
            raise RuntimeError("Unexpected georeferenced OPERA HDF layout")
        invalid=[float(attrs["nodata"]),float(attrs["undetect"])]
        for name,(r,c,_,_) in crop.items():
            raw=ds[r-radius:r+radius,c-radius:c+radius].astype(np.float32)
            valid=np.isfinite(raw) & (raw>-100)
            wet=np.where(valid,np.clip(raw,0,65),0)
            radars[name].append((wet,valid))
    print("RADAR_LOADED",time.isoformat(),len(req.content),flush=True)

def optical_flow_persist(older,prev,current,lead):
    # Use two consecutive flow fields, robust spatial filtering and a speed
    # limit. The outputs are meteorological *experiments*, not user promises.
    def byte(img):
        return (np.clip((img-5)*5,0,255)).astype(np.uint8)
    a,b,c=map(byte,(older,prev,current))
    opts=dict(pyr_scale=.5,levels=4,winsize=25,iterations=4,poly_n=7,poly_sigma=1.5,flags=0)
    f1=cv2.calcOpticalFlowFarneback(a,b,None,**opts)
    f2=cv2.calcOpticalFlowFarneback(b,c,None,**opts)
    flow=cv2.GaussianBlur(0.3*f1+0.7*f2,(0,0),sigmaX=7)
    flow=np.clip(flow,-15,15)
    rows,cols=c.shape
    xx,yy=np.meshgrid(np.arange(cols,dtype=np.float32),np.arange(rows,dtype=np.float32))
    predicted=cv2.remap(current,xx-lead*flow[:,:,0],yy-lead*flow[:,:,1],
                        interpolation=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=0)
    return predicted,flow

def metrics(pred,actual,valid):
    # Reflectivity >= 10 dBZ = wet radar signal proxy, NOT surface rain yes/no.
    binary=(pred>=10)&valid
    truth=(actual>=10)&valid
    tp=int((binary&truth).sum())
    fp=int((binary&~truth&valid).sum())
    fn=int((~binary&truth).sum())
    f1=(2*tp/(2*tp+fp+fn)) if 2*tp+fp+fn else float('nan')
    mae=float(np.mean(np.abs(pred[valid]-actual[valid]))) if valid.any() else float('nan')
    return {"f1":round(f1,4),"mae_dbz":round(mae,3),"hits":tp,"false":fp,"missed":fn}

scores=[]
visuals=[]
# Sequence: train up to index 5 or 7, valid future as t+5/t+15.
for name,sequence in radars.items():
    for index in (4,6):
      if index+3>=len(sequence):continue
      old=sequence[index-2][0]
      prev=sequence[index-1][0]
      cur,valid=sequence[index]
      for step in (1,3):
        target,truth_valid=sequence[index+step]
        overlap=valid & truth_valid
        # Need meaningful precipitation activity; don't award accuracy for dry images.
        if overlap.mean()<0.15:continue
        rainfall=(target>=10)&overlap
        wet_frac=float(rainfall.mean())
        if wet_frac<.005:continue
        forecast,flow=optical_flow_persist(old,prev,cur,step)
        m=metrics(forecast,target,overlap)
        baseline=metrics(cur,target,overlap)
        # A falsification control: could apparent skill just be spatial
        # smoothing, rather than correct motion? Compare identical
        # Gaussian smoothing without any flow field.
        smooth=cv2.GaussianBlur(cur,(0,0),sigmaX=0.85)
        smoothing=metrics(smooth,target,overlap)
        temporal=metrics(0.6*cur+0.3*prev+0.1*old,target,overlap)
        flow_mag=np.linalg.norm(flow,axis=2)
        active=cur>=10
        row={"city":name,"location":crop[name][2:],"base":times[index].isoformat(),
             "lead_min":step*5,"wet_fraction":round(wet_frac,4),
             "flow":m,"persistence":baseline,"smooth_only":smoothing,"temporal_only":temporal,
             "f1_gain":round(m["f1"]-baseline["f1"],4),
             "mae_gain":round(baseline["mae_dbz"]-m["mae_dbz"],3),
             "gain_vs_smoothing":round(m["f1"]-smoothing["f1"],4),
             "gain_vs_temporal":round(m["f1"]-temporal["f1"],4),
             "displacement_px_p50_wet":round(float(np.median(flow_mag[active])),3) if active.any() else 0}
        scores.append(row)
        if len(visuals)<5 and step==3:
            visuals.append((name,row,cur,forecast,target))
        print("SCORE",json.dumps(row),flush=True)
if visuals:
    fig,axes=plt.subplots(len(visuals),3,figsize=(10,3*len(visuals)),squeeze=False)
    for i,(name,row,nowcast,pred,actual) in enumerate(visuals):
        for j,(img,title) in enumerate(((nowcast,"Radar base"),(pred,"Flow +15 min"),(actual,"Radar real +15 min"))):
            axes[i,j].imshow(np.where(img>=7,img,np.nan),vmin=8,vmax=50,cmap="turbo")
            axes[i,j].set_title(f"{name}: {title}")
            axes[i,j].axis("off")
    plt.tight_layout()
    fig.savefig("radar-science/optical-flow-backtest.png",dpi=135)
    plt.close(fig)
summary={"time":now.isoformat(),"frames":len(files),"tested_regions":len(crop),
         "cases":len(scores),"cases_in_spain":sum(x["city"] in {p[0] for p in cities[:6]} for x in scores),
         "median_f1_gain":float(np.median([x["f1_gain"] for x in scores])) if scores else None,
         "median_mae_gain":float(np.median([x["mae_gain"] for x in scores])) if scores else None,
         "median_gain_vs_smoothing":float(np.median([x["gain_vs_smoothing"] for x in scores])) if scores else None,
         "median_gain_vs_temporal":float(np.median([x["gain_vs_temporal"] for x in scores])) if scores else None,
         "wins_over_smoothing":sum(x["gain_vs_smoothing"]>0 for x in scores),
         "f1_wins":sum(x["f1_gain"]>0 for x in scores),
         "f1_losses":sum(x["f1_gain"]<0 for x in scores),
         "results":scores}
json.dump(summary,open("radar-science/backtest.json","w"),indent=2,ensure_ascii=False)
print("BACKTEST_SUMMARY",json.dumps({k:v for k,v in summary.items() if k!="results"}),flush=True)
if len(scores)<3:
    raise RuntimeError("Insufficient rainy locations to assess nowcast objectively; no shipping approval")
# CI succeeds even when experimental optical flow is worse; skill is shown
# in results and only a further independent pass can approve a shipping model.
