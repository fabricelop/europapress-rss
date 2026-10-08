export const HARMONIE_MAX_TAR_BYTES=180*1024*1024;

export const HARMONIE_PRECIP_PALETTE=[
  {low:300,high:null,rgba:[236,200,200,255]},
  {low:250,high:300,rgba:[219,141,140,255]},
  {low:180,high:250,rgba:[204,84,83,255]},
  {low:120,high:180,rgba:[255,0,0,255]},
  {low:100,high:120,rgba:[255,61,3,255]},
  {low:80,high:100,rgba:[255,122,8,255]},
  {low:60,high:80,rgba:[255,186,15,255]},
  {low:40,high:60,rgba:[255,255,0,255]},
  {low:30,high:40,rgba:[191,230,0,255]},
  {low:20,high:30,rgba:[128,204,0,255]},
  {low:10,high:20,rgba:[0,153,0,255]},
  {low:5,high:10,rgba:[0,178,64,255]},
  {low:2,high:5,rgba:[0,204,128,255]},
  {low:1,high:2,rgba:[51,245,222,255]},
  {low:.5,high:1,rgba:[176,224,230,255]},
  {low:0,high:.5,rgba:[19,49,52,0]}
];

export function parseTarEntries(buffer,{maxEntryBytes=HARMONIE_MAX_TAR_BYTES}={}){
  const out=[];
  for(let offset=0;offset+512<=buffer.length;){
    const header=buffer.subarray(offset,offset+512);
    const name=header.subarray(0,100).toString("utf8").replace(/\0.*$/,"");
    if(!name)break;
    const sizeText=header.subarray(124,136).toString("ascii").replace(/\0.*$/,"").trim();
    const size=parseInt(sizeText||"0",8)||0;
    if(size<0||size>maxEntryBytes)throw new Error("AEMET HARMONIE: tamaño TAR inválido");
    const start=offset+512,end=start+size;
    if(end>buffer.length)throw new Error("AEMET HARMONIE: TAR truncado");
    out.push({name,size,start,end});
    offset=start+Math.ceil(size/512)*512;
  }
  return out;
}

export function decodeHarmoniePrecipRgba(r,g,b,a){
  let best=HARMONIE_PRECIP_PALETTE.at(-1),distance=Infinity;
  for(const item of HARMONIE_PRECIP_PALETTE){
    const [pr,pg,pb,pa]=item.rgba;
    const d=(Number(r)-pr)**2+(Number(g)-pg)**2+(Number(b)-pb)**2+.10*(Number(a)-pa)**2;
    if(d<distance){distance=d;best=item}
  }
  const estimate=best.low<.5?0:best.high==null?best.low:(best.low+best.high)/2;
  return{low:best.low,high:best.high,estimate,distance};
}
