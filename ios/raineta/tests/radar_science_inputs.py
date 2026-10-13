#!/usr/bin/env python3
"""Check live 1 km OPERA HDF5 array semantics and usable source shape."""
import datetime as dt,io,json,os,requests,h5py,numpy as np,tarfile
now=dt.datetime.now(dt.timezone.utc).replace(second=0,microsecond=0)
now-=dt.timedelta(minutes=now.minute%5)
os.makedirs("radar-science",exist_ok=True)
s=requests.Session()
scan=[]
for delay in (20,25,30,35,40,45,50,55):
  at=now-dt.timedelta(minutes=delay)
  url=("https://s3.waw3-1.cloudferro.com/openradar-24h/"+
    at.strftime("%Y/%m/%d/OPERA/COMP/OPERA@%Y%m%dT%H%M@0@DBZH.h5"))
  try:
    r=s.get(url,timeout=15)
    if r.status_code!=200:continue
    with h5py.File(io.BytesIO(r.content),"r") as ds:
      keys=list(ds.keys())
      attrs={k:dict(ds[k].attrs) for k in ("what","where","how") if k in ds}
      groups=[]
      for k in keys:
       if k.startswith("dataset"):
        member=ds[k]
        g={"key":k,"keys":list(member.keys())}
        for dk in member:
         if dk.startswith("data"):
          data=member[dk]
          g[dk]={"shape":data["data"].shape,"dtype":str(data["data"].dtype),
                 "what":{n:(v.decode("utf-8","replace") if isinstance(v,bytes) else float(v) if isinstance(v,np.number) else str(v)) for n,v in data["what"].attrs.items()}}
          arr=data["data"][()]
          values,count=np.unique(arr,return_counts=True)
          g[dk]["top"]=[[int(a),int(b)] for a,b in sorted(zip(values,count),key=lambda x:x[1],reverse=True)[:8]]
          g[dk]["wet_fraction"]=float(np.mean(arr>np.percentile(arr,95)))
        groups.append(g)
      info={"time":at.isoformat(),"bytes":len(r.content),"keys":keys,
            "attrs":{k:{name:(v.decode("utf-8","replace") if isinstance(v,bytes) else float(v) if isinstance(v,np.number) else str(v)) for name,v in attrs[k].items()} for k in attrs},"groups":groups}
      print("RADAR",json.dumps(info)[:6000],flush=True)
      scan.append(info)
      if len(scan)>=4:break
  except Exception as e:print("RADAR-ERROR",at.isoformat(),repr(e),flush=True)
try:
  url="https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB"
  response=s.get(url,stream=True,timeout=(10,30))
  result={"status":response.status_code,"content_type":response.headers.get("Content-Type")}
  try:
   with tarfile.open(fileobj=response.raw,mode="r|gz") as tar:
    first=[]
    for i,member in enumerate(tar):
     first.append({"name":member.name,"bytes":member.size})
     if i>=5:break
   result["first_files"]=first
  except Exception as e:result["archive_error"]=repr(e)
  response.close()
  print("HARMONIE",json.dumps(result),flush=True)
except Exception as e:print("HARMONIE-ERROR",repr(e),flush=True)
json.dump({"radar":scan},open("radar-science/structure.json","w"),indent=2)
if len(scan)<3:raise RuntimeError("Too few actual 5-minute composite radar files")
