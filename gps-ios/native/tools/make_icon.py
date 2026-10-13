#!/usr/bin/env python3
"""Icono GPS Premium: pin, mosaico, recorrido y reloj (1024 PNG RGB).
Usa exclusivamente la biblioteca estándar para funcionar en macOS Actions.
"""
from pathlib import Path
import json, math, struct, zlib

out=Path(__file__).resolve().parents[1]/"Resources.xcassets"/"AppIcon.appiconset"
out.mkdir(parents=True,exist_ok=True)
W=H=1024

def segdist(px,py,ax,ay,bx,by):
    vx=bx-ax; vy=by-ay
    u=max(0.,min(1.,((px-ax)*vx+(py-ay)*vy)/(vx*vx+vy*vy)))
    return math.hypot(px-ax-u*vx,py-ay-u*vy)

def triangle(x,y):
    a=(386.,448.); b=(638.,448.); c=(512.,772.)
    x1=(b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0])
    x2=(c[0]-b[0])*(y-b[1])-(c[1]-b[1])*(x-b[0])
    x3=(a[0]-c[0])*(y-c[1])-(a[1]-c[1])*(x-c[0])
    d=min(segdist(x,y,*a,*b),segdist(x,y,*b,*c),segdist(x,y,*c,*a))
    return -d if x1>=0 and x2>=0 and x3>=0 else d

def inside(x,y,points):
    odd=False
    j=len(points)-1
    for i in range(len(points)):
        xi,yi=points[i]; xj,yj=points[j]
        if (yi>y)!=(yj>y) and x<(xj-xi)*(y-yi)/(yj-yi)+xi:
            odd=not odd
        j=i
    return odd

def blend(c,t,a):
    return [c[i]*(1-a)+t[i]*a for i in range(3)]

arrow=[(447,430),(591,330),(541,494),(516,440)]
route=[(140,916),(249,879),(295,804),(372,829),(433,761)]
pixels=bytearray()
for y in range(H):
    pixels.append(0)
    for x in range(W):
        dx=x-512; dy=y-430
        rad=math.hypot(dx,dy)
        glow=max(0,1-rad/660)**2
        yy=y/1024
        c=[6+17*yy+10*glow,14+31*yy+34*glow,36+37*yy+44*glow]
        orb=math.exp(-((x-500)**2/(600*600)+(y-540)**2/(270*270)))
        c=blend(c,[8,115,140],0.18*orb)
        seed=(x*139+y*719+x*y*17)&65535
        if seed<4 and y<700: c=blend(c,[99,204,228],0.5)
        if y>555:
            t=(y-550)/480
            nearest=min(abs(x-(512+(target-512)*max(0,t)**1.32))
                for target in (-610,-165,190,490,790,1180,1640))
            hband=abs((t*5.5+0.06)**0.75*200%105-52)
            lines=max(0,1-nearest/2.5)*0.25+max(0,1-hband/2.7)*0.12
            c=blend(c,[24,217,237],min(0.43,lines)*(0.25+0.75*t))
        g=math.exp(-((rad-170)/65)**2)*0.45
        c=blend(c,[6,242,245],g)
        dc=math.hypot(x-512,y-403)-163
        dt=triangle(x,y)
        pin=min(dc,dt)
        if pin<12:
            c=blend(c,[45,255,248],max(0,1-abs(pin)/14)*0.6)
        if pin<0:
            if pin>-16:
                c=blend(c,[35,254,248],0.9)
            else:
                c=blend(c,[5,91,120],0.9)
                c=blend(c,[0,20,47],min(0.85,max(0,(-pin-15)/100)))
        dh=math.hypot(x-512,y-403)-101
        if dh<7:
            c=blend(c,[14,216,231],max(0,1-abs(dh)/11)*0.9)
        if dh<0:
            c=blend(c,[2,29,62],0.98)
            if inside(x,y,arrow):c=blend(c,[194,255,255],0.96)
            da=min(segdist(x,y,*arrow[i],*arrow[(i+1)%len(arrow)])
                for i in range(len(arrow)))
            if da<5:c=blend(c,[43,244,244],0.75)
        if y>740:
            d=min(segdist(x,y,*route[i],*route[i+1])
                for i in range(len(route)-1))
            if d<13:c=blend(c,[22,250,218],max(0,0.65-d/20))
            if d<4:c=blend(c,[245,196,73],0.92)
        cr=math.hypot(x-737,y-764)
        if cr<109:c=blend(c,[0,185,211],max(0,1-abs(cr-98)/16)*0.5)
        if cr<99:c=blend(c,[4,37,66],0.97)
        if 83<cr<94:c=blend(c,[89,254,248],0.92)
        if cr<83:
            hand1=segdist(x,y,737,764,737,716)
            hand2=segdist(x,y,737,764,773,780)
            if min(hand1,hand2)<8:c=blend(c,[248,251,222],0.96)
            if cr<9:c=blend(c,[255,220,103],0.98)
        if y<125:c=blend(c,[54,158,189],0.035*(125-y)/125)
        pixels.extend(bytes(max(0,min(255,round(v))) for v in c))

def chunk(kind,data):
    val=kind+data
    return struct.pack(">I",len(data))+val+struct.pack(">I",zlib.crc32(val)&0xffffffff)

image=b"\x89PNG\r\n\x1a\n"
image+=chunk(b"IHDR",struct.pack(">IIBBBBB",W,H,8,2,0,0,0))
image+=chunk(b"IDAT",zlib.compress(bytes(pixels),8))
image+=chunk(b"IEND",b"")
(out/"AppIcon.png").write_bytes(image)
(out/"Contents.json").write_text(json.dumps({
    "images":[{"filename":"AppIcon.png","idiom":"universal",
               "platform":"ios","size":"1024x1024"}],
    "info":{"author":"xcode","version":1}},indent=2)+"\n",encoding="utf-8")
print("Icono Mi Mapa del Tiempo v1.0.27:",out/"AppIcon.png")
