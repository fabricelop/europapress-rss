#!/usr/bin/env python3
"""Assess FULL forecast raster sources; never substitute sparse point grids."""
import re,xml.etree.ElementTree as ET
import urllib.request,urllib.parse,json
urls={
 "AEMET-HARMONIE-PB":"https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB",
 "DWD-ICON-WMS":"https://maps.dwd.de/geoserver/dwd/wms?service=WMS&version=1.1.1&request=GetCapabilities"
}
for name,url in urls.items():
 print("SOURCE",name)
 try:
  req=urllib.request.Request(url,method="HEAD",headers={"User-Agent":"RainETA / research into public meteorological services"})
  with urllib.request.urlopen(req,timeout=25) as response:
   print("HEAD",response.status,"type",response.headers.get("Content-Type"),
         "size",response.headers.get("Content-Length"),"final",response.url)
 except Exception as e:print("HEAD FAIL",str(e))
 if name=="DWD-ICON-WMS":
  try:
   req=urllib.request.Request(url,headers={"User-Agent":"RainETA / research"})
   with urllib.request.urlopen(req,timeout=30) as response:
    document=response.read(12*1024*1024)
   root=ET.fromstring(document)
   count=0
   for layer in root.iter():
    if layer.tag.lower().endswith("layer"):
     names=[x.text for x in layer if x.tag.lower().endswith("name") and x.text]
     title=[x.text for x in layer if x.tag.lower().endswith("title") and x.text]
     if names and (any("prec" in n.lower() or "niederschlag" in n.lower() for n in names+title)):
      count+=1
      if count<30:
       times=[x.text[:170] for x in layer if x.tag.lower().endswith("dimension") or x.tag.lower().endswith("extent") if x.text]
       print("LAYER",names[0],"TITLE",title[0] if title else "","TIMES",times[:2])
   print("MATCHING LAYERS",count)
  except Exception as e:print("GET CAPABILITIES FAIL",str(e))
