import {
  estimateTranslation,combineMotionEstimates,estimateLocalFlow,combineLocalFlows,
  evolutionReliability,flowVectorAt
} from '../rain/radar-core.js';

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
function dbzToRate(dbz){
  if(!Number.isFinite(Number(dbz))||Number(dbz)<10)return 0;
  return Math.min(80,(10**(Number(dbz)/10)/200)**(1/1.6));
}
function rateToRgba(rate,alphaScale=1){
  const r=Math.max(0,Number(rate)||0);
  if(r<=0)return[0,0,0,0];
  const dbz=10*Math.log10(Math.max(1,200*(r**1.6)));
  let best=UNIVERSAL_BLUE_ANCHORS.find(x=>x.dbz>=10),dist=Infinity;
  for(const entry of UNIVERSAL_BLUE_ANCHORS){
    if(entry.dbz<10)continue;
    const d=Math.abs(entry.dbz-dbz);
    if(d<dist){dist=d;best=entry}
  }
  const [red,green,blue,alpha]=best.rgba;
  return[red,green,blue,Math.max(45,Math.min(255,Math.round((alpha||220)*Math.max(.15,Math.min(1,alphaScale)))))];
}
export function decodeRadarTileField(raw,width,height,channels=4){
  const w=Number(width),h=Number(height),c=Number(channels);
  if(!Number.isInteger(w)||!Number.isInteger(h)||w<=0||h<=0||c<3)throw new Error('invalid_image');
  if(!raw||raw.length<w*h*c)throw new Error('invalid_pixels');
  const mask=new Uint8Array(w*h),rateGrid=new Float32Array(w*h);
  let sourceAlphaPixels=0,wetPixels=0;
  for(let i=0,p=0;i<w*h;i++,p+=c){
    const alpha=c>=4?Number(raw[p+3]):255;
    if(alpha>0)sourceAlphaPixels++;
    const entry=radarDbzFromUniversalBlue(raw[p],raw[p+1],raw[p+2],alpha);
    if(!entry||entry.dbz<10)continue;
    mask[i]=1;rateGrid[i]=dbzToRate(entry.dbz);wetPixels++;
  }
  return{mask,rateGrid,width:w,height:h,sourceAlphaPixels,wetPixels,wetFraction:wetPixels/(w*h),sourceAlphaFraction:sourceAlphaPixels/(w*h)};
}
export function renderRadarFieldRgba(field,{alphaScale=1}={}){
  const w=Number(field?.width),h=Number(field?.height);
  if(!Number.isInteger(w)||!Number.isInteger(h)||!field?.mask?.length||!field?.rateGrid?.length)throw new Error('invalid_field');
  const rgba=new Uint8ClampedArray(w*h*4);
  let wetPixels=0;
  for(let i=0,o=0;i<w*h;i++,o+=4){
    if(!field.mask[i])continue;
    const rate=Number(field.rateGrid[i])||0;
    if(rate<=0)continue;
    const [r,g,b,a]=rateToRgba(rate,alphaScale);
    rgba[o]=r;rgba[o+1]=g;rgba[o+2]=b;rgba[o+3]=a;wetPixels++;
  }
  return{rgba,wetPixels,wetFraction:wetPixels/(w*h)};
}
export function reconstructRadarTileRgba(raw,width,height,channels=4){
  const field=decodeRadarTileField(raw,width,height,channels);
  return{...renderRadarFieldRgba(field),sourceAlphaPixels:field.sourceAlphaPixels,sourceAlphaFraction:field.sourceAlphaFraction};
}
function median(values=[]){
  const a=values.filter(Number.isFinite).sort((x,y)=>x-y);
  if(!a.length)return null;
  const m=Math.floor(a.length/2);
  return a.length%2?a[m]:(a[m-1]+a[m])/2;
}
function downsampleField(field,target=96){
  const w=field.width,h=field.height,tw=Math.min(target,w),th=Math.min(target,h);
  const mask=new Uint8Array(tw*th),rateGrid=new Float32Array(tw*th);
  for(let ty=0;ty<th;ty++)for(let tx=0;tx<tw;tx++){
    const x0=Math.floor(tx*w/tw),x1=Math.max(x0+1,Math.floor((tx+1)*w/tw));
    const y0=Math.floor(ty*h/th),y1=Math.max(y0+1,Math.floor((ty+1)*h/th));
    let wet=0,maxRate=0;
    for(let y=y0;y<Math.min(h,y1);y++)for(let x=x0;x<Math.min(w,x1);x++){
      const i=y*w+x;
      if(field.mask[i]){wet++;maxRate=Math.max(maxRate,Number(field.rateGrid[i])||0)}
    }
    const o=ty*tw+tx;
    if(wet){mask[o]=1;rateGrid[o]=maxRate}
  }
  return{mask,rateGrid,width:tw,height:th};
}
function emptyFuture(width,height,status,meta={}){
  return{status,field:{mask:new Uint8Array(width*height),rateGrid:new Float32Array(width*height),width,height},horizon:0,localQuality:0,flowVectors:0,...meta};
}
export function buildSyntheticFutureField(fields=[],times=[],minutes=0,{persistenceMinutes=5}={}){
  const valid=fields.filter(f=>f?.mask?.length&&f?.rateGrid?.length);
  if(!valid.length)return emptyFuture(256,256,'no_fields');
  const latest=valid.at(-1),w=latest.width,h=latest.height,m=Math.max(0,Number(minutes)||0);
  if(m<=3)return{status:'persistence',field:latest,horizon:3,localQuality:0,flowVectors:0};
  const usable=valid.slice(-4),timeValues=times.slice(-usable.length).map(Number);
  if(usable.length<3){
    if(m<=persistenceMinutes)return{status:'short_persistence',field:latest,horizon:persistenceMinutes,localQuality:0,flowVectors:0};
    return emptyFuture(w,h,'insufficient_history');
  }
  const reduced=usable.map(f=>downsampleField(f,96));
  const estimates=[],flows=[];
  for(let i=1;i<reduced.length;i++){
    const prev=reduced[i-1],cur=reduced[i];
    const motion=estimateTranslation(prev.mask,cur.mask,cur.width,cur.height,{maxShift:7});
    if(motion)estimates.push(motion);
    const flow=estimateLocalFlow(prev.mask,cur.mask,cur.width,cur.height,{maxShift:6,grid:5,patchRadius:9});
    if(flow)flows.push(flow);
  }
  const motion=combineMotionEstimates(estimates),flow=combineLocalFlows(flows);
  const localQuality=Math.max(0,Math.min(1,(Number(flow?.confidence)||0)*.65+(Number(flow?.coverage)||0)*.35));
  const evolution=motion?evolutionReliability(reduced.at(-2).mask,reduced.at(-1).mask,reduced.at(-1).width,reduced.at(-1).height,motion):{score:0};
  const steps=[];
  for(let i=1;i<timeValues.length;i++){
    const d=(timeValues[i]-timeValues[i-1])/60;
    if(Number.isFinite(d)&&d>0&&d<=30)steps.push(d);
  }
  const sourceStep=median(steps)||10;
  let horizon=localQuality>=.62?45:localQuality>=.50?36:localQuality>=.38?28:localQuality>=.28?20:localQuality>=.20?14:0;
  if(Number(evolution.score)<.28)horizon=Math.min(horizon,12);
  if(Number(evolution.score)<.18)horizon=0;
  const flowUsable=Boolean(flow?.vectors?.length>=5&&localQuality>=.20&&horizon>=m);
  if(!flowUsable){
    if(m<=persistenceMinutes)return{status:'short_persistence',field:latest,horizon:persistenceMinutes,localQuality,flowVectors:flow?.vectors?.length||0,evolution:Number(evolution.score)||0};
    return emptyFuture(w,h,'uncertain',{localQuality,flowVectors:flow?.vectors?.length||0,evolution:Number(evolution.score)||0,horizon});
  }
  const outMask=new Uint8Array(w*h),outRate=new Float32Array(w*h);
  const rw=reduced.at(-1).width,rh=reduced.at(-1).height;
  const lookupStep=8,lw=Math.ceil(w/lookupStep),lh=Math.ceil(h/lookupStep);
  const dxLookup=new Float32Array(lw*lh),dyLookup=new Float32Array(lw*lh),okLookup=new Uint8Array(lw*lh);
  for(let gy=0;gy<lh;gy++)for(let gx=0;gx<lw;gx++){
    const px=Math.min(w-1,gx*lookupStep+lookupStep/2),py=Math.min(h-1,gy*lookupStep+lookupStep/2);
    const fx=px*(rw-1)/Math.max(1,w-1),fy=py*(rh-1)/Math.max(1,h-1);
    const vec=flowVectorAt(flow,fx,fy,{dx:NaN,dy:NaN,confidence:0});
    const o=gy*lw+gx;
    if(!Number.isFinite(Number(vec?.dx))||!Number.isFinite(Number(vec?.dy))||Number(vec?.confidence)<.12)continue;
    dxLookup[o]=Number(vec.dx)*(w/rw);dyLookup[o]=Number(vec.dy)*(h/rh);okLookup[o]=1;
  }
  const scale=m/Math.max(1,sourceStep);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
    const i=y*w+x,rate=Number(latest.rateGrid[i])||0;
    if(!latest.mask[i]||rate<=0)continue;
    const gx=Math.min(lw-1,Math.floor(x/lookupStep)),gy=Math.min(lh-1,Math.floor(y/lookupStep)),lo=gy*lw+gx;
    if(!okLookup[lo])continue;
    const tx=x+dxLookup[lo]*scale,ty=y+dyLookup[lo]*scale;
    const x0=Math.floor(tx),y0=Math.floor(ty),fx=tx-x0,fy=ty-y0;
    for(const [xx,yy,weight] of [[x0,y0,(1-fx)*(1-fy)],[x0+1,y0,fx*(1-fy)],[x0,y0+1,(1-fx)*fy],[x0+1,y0+1,fx*fy]]){
      if(xx<0||yy<0||xx>=w||yy>=h||weight<=.08)continue;
      const o=yy*w+xx;outMask[o]=1;outRate[o]=Math.max(outRate[o],rate*Math.max(.72,weight));
    }
  }
  const wetPixels=outMask.reduce((sum,v)=>sum+(v?1:0),0);
  if(!wetPixels&&latest.wetPixels>0){
    if(m<=persistenceMinutes)return{status:'short_persistence',field:latest,horizon:persistenceMinutes,localQuality,flowVectors:flow.vectors.length,evolution:Number(evolution.score)||0};
    return emptyFuture(w,h,'empty_projection',{localQuality,flowVectors:flow.vectors.length,evolution:Number(evolution.score)||0,horizon});
  }
  return{status:'flow',field:{mask:outMask,rateGrid:outRate,width:w,height:h},horizon,localQuality,flowVectors:flow.vectors.length,evolution:Number(evolution.score)||0,sourceStepMinutes:sourceStep};
}
