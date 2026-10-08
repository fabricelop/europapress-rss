import {estimateTranslation} from './radar-core.js';

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
