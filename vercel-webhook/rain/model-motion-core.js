import {estimateTranslation,estimateLocalFlow,flowVectorAt} from './radar-core.js';

function clamp01(v){return Math.max(0,Math.min(1,Number(v)||0))}
export function precipitationMaskFromRgba(rgba,width,height,{target=64,alphaThreshold=28}={}){
  const w=Number(width),h=Number(height),tw=Math.max(8,Math.min(Number(target)||64,w)),th=Math.max(8,Math.min(Number(target)||64,h));
  if(!rgba||rgba.length<w*h*4||!Number.isInteger(w)||!Number.isInteger(h)||w<=0||h<=0)throw new Error('invalid_rgba');
  const mask=new Uint8Array(tw*th);
  for(let ty=0;ty<th;ty++)for(let tx=0;tx<tw;tx++){
    const x0=Math.floor(tx*w/tw),x1=Math.max(x0+1,Math.floor((tx+1)*w/tw));
    const y0=Math.floor(ty*h/th),y1=Math.max(y0+1,Math.floor((ty+1)*h/th));
    let maxAlpha=0;
    for(let y=y0;y<Math.min(h,y1);y++)for(let x=x0;x<Math.min(w,x1);x++){
      maxAlpha=Math.max(maxAlpha,Number(rgba[(y*w+x)*4+3])||0);
    }
    if(maxAlpha>=alphaThreshold)mask[ty*tw+tx]=1;
  }
  return{mask,width:tw,height:th};
}
export function estimateModelTileMotion(prevRgba,nextRgba,width,height,{target=64,maxShift=10,minConfidence=.16}={}){
  const a=precipitationMaskFromRgba(prevRgba,width,height,{target});
  const b=precipitationMaskFromRgba(nextRgba,width,height,{target});
  const motion=estimateTranslation(a.mask,b.mask,a.width,a.height,{maxShift});
  if(!motion||Number(motion.confidence)<minConfidence)return{ok:false,dx:0,dy:0,confidence:Number(motion?.confidence)||0};
  const dx=Number(motion.dx)*(Number(width)/a.width),dy=Number(motion.dy)*(Number(height)/a.height);
  const limit=Math.max(8,Math.min(Number(width),Number(height))*.24);
  const mag=Math.hypot(dx,dy);
  if(!Number.isFinite(mag)||mag>limit)return{ok:false,dx:0,dy:0,confidence:Number(motion.confidence)||0};
  return{ok:true,dx,dy,confidence:Number(motion.confidence),score:Number(motion.score)||0};
}
export function estimateModelTileLocalFlow(prevRgba,nextRgba,width,height,{target=72,maxShift=8,grid=6,patchRadius=8,minConfidence=.18,minCoverage=.22}={}){
  const a=precipitationMaskFromRgba(prevRgba,width,height,{target});
  const b=precipitationMaskFromRgba(nextRgba,width,height,{target});
  const flow=estimateLocalFlow(a.mask,b.mask,a.width,a.height,{maxShift,grid,patchRadius});
  const confidence=Number(flow?.confidence)||0,coverage=Number(flow?.coverage)||0;
  const ok=Boolean(flow?.vectors?.length>=5&&confidence>=minConfidence&&coverage>=minCoverage);
  return{
    ok,flow:flow||null,confidence,coverage,
    imageWidth:Number(width),imageHeight:Number(height),
    maskWidth:a.width,maskHeight:a.height,
    scaleX:Number(width)/a.width,scaleY:Number(height)/a.height
  };
}
export function modelMotionSingleFramePlan(fraction,motion){
  const f=clamp01(fraction),ok=Boolean(motion?.ok),useTo=f>=.5;
  const dx=ok?Number(motion.dx)||0:0,dy=ok?Number(motion.dy)||0:0;
  return{
    fraction:f,
    source:useTo?'to':'from',
    dx:ok?(useTo?-dx*(1-f):dx*f):0,
    dy:ok?(useTo?-dy*(1-f):dy*f):0,
    motionApplied:ok
  };
}
export function modelLocalPatchDisplacement(localMotion,x,y,fraction,source='from',fallback={dx:0,dy:0}){
  if(!localMotion?.ok||!localMotion?.flow?.vectors?.length)return{...fallback,confidence:0,local:false};
  const iw=Math.max(1,Number(localMotion.imageWidth)||1),ih=Math.max(1,Number(localMotion.imageHeight)||1);
  const mw=Math.max(1,Number(localMotion.maskWidth)||1),mh=Math.max(1,Number(localMotion.maskHeight)||1);
  const fx=Number(x)*(mw-1)/Math.max(1,iw-1),fy=Number(y)*(mh-1)/Math.max(1,ih-1);
  const vec=flowVectorAt(localMotion.flow,fx,fy,{dx:NaN,dy:NaN,confidence:0});
  if(!Number.isFinite(Number(vec?.dx))||!Number.isFinite(Number(vec?.dy))||Number(vec?.confidence)<.12){
    return{...fallback,confidence:Number(vec?.confidence)||0,local:false};
  }
  const f=clamp01(fraction),factor=source==='to'?-(1-f):f;
  return{
    dx:Number(vec.dx)*(Number(localMotion.scaleX)||1)*factor,
    dy:Number(vec.dy)*(Number(localMotion.scaleY)||1)*factor,
    confidence:Number(vec.confidence)||0,
    local:true
  };
}
