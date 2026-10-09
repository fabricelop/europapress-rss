
// Radar observado RainViewer: one tile centered on point, no proxy/server.
// RainViewer pixel colors use Universal Blue (2); >~12 dBZ alpha >170.
// This indicates echoes aloft; it does NOT prove rain reaches the ground.
const RADAR_OBS_CACHE="RainETAWidget:radar-observed:v1:";
function radarObsLabel(obs){
  if(obs.status==="echo")return"RADAR AHORA · Eco de precipitación · "+obs.time;
  if(obs.status==="clear")return"RADAR AHORA · Sin eco detectado · "+obs.time;
  if(obs.status==="stale")return"RADAR: última imagen demasiado antigua";
  if(obs.status==="outside")return"RADAR: sin cobertura confirmada";
  return"RADAR: sin datos fiables";
}
async function radarPngSample(data){
  // Decode a real radar PNG in isolated WebKit canvas to inspect image pixels.
  // A transparent radar tile alone is ambiguous without a coverage tile.
  const web=new WebView();
  await web.loadHTML("<!doctype html><html><body></body></html>");
  const uri="data:image/png;base64,"+data.toBase64String();
  const expression="(function(){"+
    "var im=new Image();im.onload=function(){try{"+
    "var c=document.createElement('canvas');c.width=im.width;c.height=im.height;"+
    "var context=c.getContext('2d',{willReadFrequently:true});context.drawImage(im,0,0);"+
    "var a=context.getImageData(0,0,c.width,c.height).data;"+
    "var cx=Math.floor(c.width/2),cy=Math.floor(c.height/2),strong=0,transparent=0,n=0;"+
    "for(var y=cy-4;y<=cy+4;y++)for(var x=cx-4;x<=cx+4;x++){"+
    "var i=(y*c.width+x)*4,alpha=a[i+3];n++;if(alpha>=180)strong++;if(alpha<=40)transparent++;}"+
    "completion({ok:true,strong:strong,transparent:transparent,total:n});"+
    "}catch(e){completion({ok:false,error:String(e)})}};"+
    "im.onerror=function(){completion({ok:false,error:'image decode'})};im.src="+JSON.stringify(uri)+";"+
    "})();";
  const value=await web.evaluateJavaScript(expression,true);
  if(!value?.ok||!Number.isFinite(value.total)||value.total<16)throw Error("radar_png_invalid");
  return value;
}
async function radarObservadoAt(place){
  const lat=Number(place.lat),lon=Number(place.lon);
  if(!Number.isFinite(lat)||!Number.isFinite(lon)||Math.abs(lat)>85||Math.abs(lon)>180)
    return{status:"outside"};
  const key=RADAR_OBS_CACHE+lat.toFixed(2)+","+lon.toFixed(2);
  try{
    if(Keychain.contains(key)){
      const recent=JSON.parse(Keychain.get(key));
      if(Date.now()-recent.checkedAt<5*60000&&Date.now()-recent.frameAt<25*60000)
        return recent;
    }
  }catch(_){}
  try{
    const req=new Request("https://api.rainviewer.com/public/weather-maps.json");
    req.timeoutInterval=9;
    const manifest=await req.loadJSON(),frames=manifest?.radar?.past||[];
    const newest=frames.filter(f=>Number.isFinite(Number(f.time))).sort((a,b)=>a.time-b.time).at(-1);
    if(!newest||!manifest?.host||!/^https:\/\/[a-z0-9.-]+\.rainviewer\.com$/i.test(manifest.host))
      return{status:"unavailable"};
    const frameAt=Number(newest.time)*1000,age=Date.now()-frameAt;
    if(age < -3*60000||age>25*60000)return{status:"stale"};
    const center=lat.toFixed(4)+"/"+lon.toFixed(4);
    const base=manifest.host.replace(/\/$/,"");
    const prefix=base+String(newest.path)+"/256/7/"+center;
    const coverageUrl=base+"/v2/coverage/0/256/7/"+center+"/0/0_0.png";
    const radarRequest=new Request(prefix+"/2/0_0.png");
    const coverageRequest=new Request(coverageUrl);
    radarRequest.timeoutInterval=12;
    coverageRequest.timeoutInterval=12;
    const blobs=await Promise.all([radarRequest.load(),coverageRequest.load()]);
    const coverage=await radarPngSample(blobs[1]);
    if(coverage.transparent/coverage.total<.7)return{status:"outside"};
    const sample=await radarPngSample(blobs[0]);
    const isEcho=sample.strong>=3;
    const value={status:isEcho?"echo":"clear",
      frameAt,checkedAt:Date.now(),time:hhmm(frameAt),
      radarPoints:sample.strong,radarTotal:sample.total};
    try{Keychain.set(key,JSON.stringify(value))}catch(_){}
    return value;
  }catch(error){
    return{status:"unavailable",error:String(error)};
  }
}
