#!/usr/bin/env python3
"""Construye un icono real de iPhone (PNG RGB 1024) sin bibliotecas externas."""
from pathlib import Path
import json, math, struct, zlib

out = Path(__file__).resolve().parents[1] / "Resources.xcassets" / "AppIcon.appiconset"
out.mkdir(parents=True, exist_ok=True)
w = h = 1024
pixels = bytearray()
for y in range(h):
    pixels.append(0)  # Filtro PNG = None
    for x in range(w):
        tint = 1 - 0.20 * (x+y)/2048
        rgb = [int(14*tint),int(60*tint),int(82*tint)]
        if 112 < x < 912 and 112 < y < 912:
            cx,cy=(x-112)//200,(y-112)//200
            dx,dy=(x-112)%200,(y-112)%200
            if 8 < dx < 192 and 8 < dy < 192:
                rgb = [21,133,152] if cx in (1,2) and cy in (1,2) else [20,93,121]
        r=math.hypot(x-512,y-512)
        if r < 164: rgb=[243,248,244]
        if r < 148: rgb=[17,77,100]
        if r < 131: rgb=[20,114,135]
        if (abs(x-512)<10 and 390<y<512) or (abs(y-(512+0.7*(x-512)))<10 and 512<x<605):
            rgb=[252,221,121]
        if r<15: rgb=[255,231,145]
        pixels.extend(rgb)
def chunk(kind,data):
    val=kind+data
    return struct.pack(">I",len(data))+val+struct.pack(">I",zlib.crc32(val)&0xffffffff)
image=b"\x89PNG\r\n\x1a\n"
image+=chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))
image+=chunk(b"IDAT",zlib.compress(bytes(pixels),9))
image+=chunk(b"IEND",b"")
(out/"AppIcon.png").write_bytes(image)
(out/"Contents.json").write_text(json.dumps({"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}},indent=2)+"\n",encoding="utf-8")
print("Icono generado:",out/"AppIcon.png")
