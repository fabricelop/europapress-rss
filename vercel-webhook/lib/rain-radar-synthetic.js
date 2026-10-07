export const RAINVIEWER_HOST='https://tilecache.rainviewer.com';

export const UNIVERSAL_BLUE_ANCHORS=[
  {dbz:0,rgba:[130,123,105,73]},
  {dbz:5,rgba:[146,136,113,100]},
  {dbz:10,rgba:[206,192,135,150]},
  {dbz:15,rgba:[136,221,238,255]},
  {dbz:20,rgba:[0,163,224,255]},
  {dbz:25,rgba:[0,119,170,255]},
  {dbz:30,rgba:[0,85,136,255]},
  {dbz:35,rgba:[255,238,0,255]},
  {dbz:40,rgba:[255,170,0,255]},
  {dbz:45,rgba:[255,68,0,255]},
  {dbz:50,rgba:[193,0,0,255]},
  {dbz:55,rgba:[255,170,255,255]},
  {dbz:60,rgba:[255,119,255,255]},
  {dbz:65,rgba:[255,255,255,255]}
];

export function validateRainViewerFramePath(value){
  const frame=String(value||'').trim();
  if(!/^\/v2\/radar\/[A-Za-z0-9_-]{4,64}$/.test(frame))throw new Error('invalid_frame');
  return frame;
}
export function validateRadarTileCoordinate(value,name='tile'){
  const n=Number(value);
  if(!Number.isInteger(n)||n<0)throw new Error('invalid_'+name);
  return n;
}
export function buildRainViewerSourceTileUrl({frame,z,x,y,size=256}){
  const f=validateRainViewerFramePath(frame);
  const zz=validateRadarTileCoordinate(z,'z');
  if(zz>7)throw new Error('invalid_z');
  const max=2**zz;
  const xx=validateRadarTileCoordinate(x,'x'),yy=validateRadarTileCoordinate(y,'y');
  if(xx>=max||yy>=max)throw new Error('invalid_xy');
  const s=Number(size)===512?512:256;
  return RAINVIEWER_HOST+f+'/'+s+'/'+zz+'/'+xx+'/'+yy+'/2/0_0.png';
}
export function radarDbzFromUniversalBlue(r,g,b,a){
  if(Number(a)<45)return null;
  let best=null,bestDist=Infinity;
  for(const entry of UNIVERSAL_BLUE_ANCHORS){
    const [er,eg,eb,ea]=entry.rgba;
    const dist=(Number(r)-er)**2+(Number(g)-eg)**2+(Number(b)-eb)**2+((Number(a)-ea)*.65)**2;
    if(dist<bestDist){bestDist=dist;best=entry}
  }
  return bestDist<7000?best:null;
}
export function reconstructRadarTileRgba(raw,width,height,channels=4){
  const w=Number(width),h=Number(height),c=Number(channels);
  if(!Number.isInteger(w)||!Number.isInteger(h)||w<=0||h<=0||c<3)throw new Error('invalid_image');
  if(!raw||raw.length<w*h*c)throw new Error('invalid_pixels');
  const out=new Uint8ClampedArray(w*h*4);
  let sourceAlphaPixels=0,wetPixels=0;
  for(let i=0,p=0,o=0;i<w*h;i++,p+=c,o+=4){
    const alpha=c>=4?Number(raw[p+3]):255;
    if(alpha>0)sourceAlphaPixels++;
    const entry=radarDbzFromUniversalBlue(raw[p],raw[p+1],raw[p+2],alpha);
    if(!entry||entry.dbz<10)continue;
    const [r,g,b,a]=entry.rgba;
    out[o]=r;out[o+1]=g;out[o+2]=b;out[o+3]=Math.max(120,Math.min(255,a||220));
    wetPixels++;
  }
  return{
    rgba:out,
    sourceAlphaPixels,
    wetPixels,
    wetFraction:wetPixels/(w*h),
    sourceAlphaFraction:sourceAlphaPixels/(w*h)
  };
}
