// RainETA — widget de lluvia para Scriptable (iPhone).
// Parámetro del widget: "Madrid", "Sevilla, España" o "40.4168,-3.7038|Madrid".
// Vacío = GPS actual. Consenso original RainETA; Open-Meteo suministra modelos. Sin Vercel.
// En Iberia, los pasos de 15 min pueden estar interpolados de modelos horarios.
const PARAM = String(args.widgetParameter || "").trim();
const LOCATION_KEY = "RainETAWidget:lastLocation";
const REFRESH_MINUTES = 20;
const FALLBACK_CITY = null; // No inventar que Madrid es la ubicación del usuario
const CACHE_KEY = 'RainETAWidget:rainetaConsensus:v1';
const FAMILY = String(config.widgetFamily||'medium');
const SMALL = FAMILY==='small'||FAMILY.startsWith('accessory');
const LARGE = FAMILY==='large'||FAMILY==='extraLarge';

function parsePosition(param) {
  const found=param.match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?:\s*\|\s*(.+))?$/);
  if (!found) return null;
  const lat=Number(found[1]),lon=Number(found[2]);
  if(Math.abs(lat)>90||Math.abs(lon)>180)return null;
  return{lat,lon,name:(found[3]||"Lugar seleccionado").slice(0,35)};
}
async function position(){
  if(PARAM){
    const p=parsePosition(PARAM);
    if(p)return p;
    return await geocodeCity(PARAM);
  }
  try {
    Location.setAccuracyToKilometer();
    const p=await Location.current();
    const loc={lat:p.latitude,lon:p.longitude,name:'Mi ubicación'};
    Keychain.set(LOCATION_KEY,JSON.stringify(loc));
    return loc;
  }catch(e){
    if(Keychain.contains(LOCATION_KEY)){
      const cached=JSON.parse(Keychain.get(LOCATION_KEY));
      if(Number.isFinite(cached.lat)&&Number.isFinite(cached.lon))return {...cached,name:"Última ubicación"};
    }
    if(FALLBACK_CITY)return FALLBACK_CITY;
    throw Error('Permite ubicación en Scriptable o fija lat,lon en el widget');
  }
}
async function getJson(url){
  const request=new Request(url);request.timeoutInterval=12;
  return await request.loadJSON();
}
async function geocodeCity(name){
  const query=name.trim().slice(0,80);
  if(query.length<2)throw Error('Escribe una ciudad, por ejemplo Madrid');
  const key='RainETAWidget:city:'+query.toLocaleLowerCase('es');
  try{
    if(Keychain.contains(key)){
      const saved=JSON.parse(Keychain.get(key));
      if(Date.now()-saved.cachedAt<7*24*3600000 && Number.isFinite(saved.lat) && Number.isFinite(saved.lon))
        return {lat:saved.lat,lon:saved.lon,name:saved.name};
    }
  }catch(_){}
  const url='https://geocoding-api.open-meteo.com/v1/search?'+
    'name='+encodeURIComponent(query)+'&count=5&language=es&format=json';
  const data=await getJson(url);
  const candidates=Array.isArray(data.results)?data.results:[];
  if(!candidates.length)throw Error('No se encuentra "'+query+'". Prueba "Ciudad, País"');
  const city=candidates[0];
  const label=[city.name,city.admin1&&city.admin1!==city.name?city.admin1:null]
    .filter(Boolean).join(', ').slice(0,36);
  const result={lat:Number(city.latitude),lon:Number(city.longitude),name:label};
  if(!Number.isFinite(result.lat)||!Number.isFinite(result.lon))throw Error('Ubicación sin coordenadas');
  Keychain.set(key,JSON.stringify({...result,cachedAt:Date.now()}));
  return result;
}

function hourlyRainRows(data, nowMs) {
  const h=(data||{}).hourly||{};
  const times=Array.isArray(h.time)?h.time:[];
  const probs=h.precipitation_probability||[];
  const rains=h.rain||[], showers=h.showers||[], totals=h.precipitation||[];
  const rows=[];
  for(let i=0;i<times.length;i++){
    // Hourly precipitation is the accumulated rain in the preceding hour.
    const end=Number(times[i])*1000;
    if(!Number.isFinite(end)||end<=nowMs)continue;
    const r=rains[i]==null?NaN:Number(rains[i]);
    const s=showers[i]==null?NaN:Number(showers[i]);
    const t=totals[i]==null?NaN:Number(totals[i]);
    const amount=Number.isFinite(r)&&Number.isFinite(s)?r+s:t;
    const p=probs[i]==null?NaN:Number(probs[i]);
    rows.push({
      start:end-3600000,end,
      probability:Number.isFinite(p)?Math.max(0,Math.min(100,Math.round(p))):null,
      mm:Number.isFinite(amount)?Math.max(0,Math.round(amount*10)/10):null
    });
    if(rows.length>=12)break;
  }
  return rows;
}
function hhmm(ms){
  const date=new Date(ms);
  return String(date.getHours()).padStart(2,'0')+':'+String(date.getMinutes()).padStart(2,'0');
}
function rainColor(mm){
  if(mm==null)return '#637e91';
  if(mm<0.1)return '#3b5262';
  if(mm<0.5)return '#62caee';
  if(mm<2.5)return '#328dff';
  if(mm<7.5)return '#8b6aff';
  return '#ff796c';
}
function drawRainBars(rows,large){
  const W=720,H=large?252:210;
  const ctx=new DrawContext();
  ctx.size=new Size(W,H);
  ctx.opaque=false;
  const baseline=large?166:135,barMax=large?118:85;
  const cell=W/12;
  function write(str,x,y,w,size,color,bold){
    ctx.setTextAlignedCenter();
    ctx.setFont(bold?Font.boldSystemFont(size):Font.systemFont(size));
    ctx.setTextColor(new Color(color));
    ctx.drawTextInRect(str,new Rect(x,y,w,29));
  }
  ctx.setFillColor(new Color('#38536a'));
  ctx.fillRect(new Rect(0,baseline,W,2));
  for(let i=0;i<12;i++){
    const row=rows[i],x=i*cell+3,w=cell-6;
    if(!row)continue;
    write(row.probability==null?'—':String(row.probability)+'%',x,4,w,20,'#e3f2fc',true);
    const mm=row.mm;
    const barHeight=mm==null?2:mm<0.1?3:Math.min(barMax,Math.max(9,12+29*Math.sqrt(mm)));
    ctx.setFillColor(new Color(rainColor(mm)));
    ctx.fillRect(new Rect(x+9,baseline-barHeight,w-18,barHeight));
    write(mm==null?'—':mm.toFixed(1).replace('.',','),x,baseline+8,w,20,'#d0e3f0',true);
    write(String(new Date(row.start).getHours()).padStart(2,'0'),x,baseline+38,w,20,'#9ec2d7',false);
  }
  return ctx.getImage();
}

const WET_THRESHOLD_MM = 0.1;

function clamp(value, min = 0, max = 1) {
  return Math.min(max, Math.max(min, Number.isFinite(value) ? value : min));
}

function median(values) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!clean.length) return null;
  const mid = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[mid] : (clean[mid - 1] + clean[mid]) / 2;
}

function percentile(values, p) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!clean.length) return null;
  if (clean.length === 1) return clean[0];
  const pos = clamp(p) * (clean.length - 1);
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  if (lo === hi) return clean[lo];
  return clean[lo] + (clean[hi] - clean[lo]) * (pos - lo);
}

function weightedAverage(items, valueKey, weightKey = 'weight') {
  let numerator = 0, denominator = 0;
  for (const item of items) {
    const value = item?.[valueKey], weight = item?.[weightKey] ?? 1;
    if (!Number.isFinite(value) || !Number.isFinite(weight) || weight <= 0) continue;
    numerator += value * weight;
    denominator += weight;
  }
  return denominator ? numerator / denominator : null;
}

function standardDeviation(values) {
  const clean = values.filter(Number.isFinite);
  if (clean.length < 2) return clean.length ? 0 : null;
  const mean = clean.reduce((a, b) => a + b, 0) / clean.length;
  const variance = clean.reduce((sum, value) => sum + (value - mean) ** 2, 0) / clean.length;
  return Math.sqrt(variance);
}

function aggregateFamilies(items, valueSelector) {
  const groups = new Map();
  for (const item of items) {
    const value = valueSelector(item);
    if (!Number.isFinite(value)) continue;
    const family = item.family || item.id || item.label || 'unknown';
    const group = groups.get(family) || { family, values: [], weight: 0 };
    group.values.push(value);
    group.weight = Math.max(group.weight, Number(item.weight) || 1);
    groups.set(family, group);
  }
  return [...groups.values()].map(group => ({
    family: group.family,
    value: group.values.reduce((sum, value) => sum + value, 0) / group.values.length,
    weight: group.weight,
  }));
}

function aggregateEnsembleModel(hourly = {}, wetThreshold = WET_THRESHOLD_MM) {
  const time = Array.isArray(hourly.time) ? hourly.time : [];
  const memberKeys = Object.keys(hourly).filter(
    key => key !== 'time' && key.startsWith('precipitation') && Array.isArray(hourly[key])
  );
  if (!time.length || !memberKeys.length) return null;
  const rows = time.map((timestamp, index) => {
    const values = memberKeys.map(key => Number(hourly[key][index])).filter(Number.isFinite);
    const wet = values.filter(value => value >= wetThreshold).length;
    return {
      time: timestamp,
      probability: values.length ? wet / values.length : null,
      median: median(values),
      p10: percentile(values, 0.1),
      p90: percentile(values, 0.9),
      members: values.length,
    };
  });
  const onsetTimes=[];
  for(const key of memberKeys){
    const values=hourly[key]||[];
    let onset=null;
    for(let i=0;i<time.length;i++){
      const value=Number(values[i]),next=Number(values[i+1]);
      if(!Number.isFinite(value))continue;
      const credible=value>=wetThreshold&&(value>=.25||(Number.isFinite(next)&&next>=Math.max(.04,wetThreshold*.5)));
      if(credible){onset=Date.parse(time[i]);break}
    }
    if(Number.isFinite(onset))onsetTimes.push(onset);
  }
  const onset=onsetTimes.length?{
    wetMembers:onsetTimes.length,
    fraction:onsetTimes.length/memberKeys.length,
    median:new Date(median(onsetTimes)).toISOString(),
    p10:new Date(percentile(onsetTimes,.10)).toISOString(),
    p20:new Date(percentile(onsetTimes,.20)).toISOString(),
    p80:new Date(percentile(onsetTimes,.80)).toISOString(),
    p90:new Date(percentile(onsetTimes,.90)).toISOString()
  }:null;
  return { memberCount: memberKeys.length, rows, onset };
}

function buildConsensus({ deterministic = [], ensembles = [], nowMs = Date.now() }) {
  const allTimes = new Set();
  deterministic.forEach(model => model.rows?.forEach(row => allTimes.add(row.time)));
  ensembles.forEach(model => model.rows?.forEach(row => allTimes.add(row.time)));
  const times = [...allTimes].sort();
  const detMaps = deterministic.map(model => ({...model, map:new Map((model.rows||[]).map(row=>[row.time,row]))}));
  const ensMaps = ensembles.map(model => ({...model, map:new Map((model.rows||[]).map(row=>[row.time,row]))}));

  return times.map(time => {
    const detAtTime = detMaps.map(model => ({...model, value:Number(model.map.get(time)?.precipitation)})).filter(model => Number.isFinite(model.value));
    const ensAtTime = ensMaps.map(model => {
      const row=model.map.get(time);
      return row ? {...model, probability:row.probability, amount:row.median} : null;
    }).filter(Boolean);

    const detWetFamilies=aggregateFamilies(detAtTime,model=>model.value>=WET_THRESHOLD_MM?1:0);
    const ensProbFamilies=aggregateFamilies(ensAtTime,model=>model.probability);
    const detAmountFamilies=aggregateFamilies(detAtTime,model=>model.value);
    const ensAmountFamilies=aggregateFamilies(ensAtTime,model=>model.amount);
    const detWet=weightedAverage(detWetFamilies,'value');
    const ensProbability=weightedAverage(ensProbFamilies,'value');
    const horizonHours = Math.max(0,(Date.parse(time)-nowMs)/3_600_000);
    const ensembleShare = horizonHours <= 6 ? 0.58 : horizonHours <= 24 ? 0.68 : 0.78;
    const probability = ensProbability == null ? (detWet ?? 0)
      : detWet == null ? ensProbability
      : ensembleShare*ensProbability + (1-ensembleShare)*detWet;

    const detMedian=median(detAmountFamilies.map(group=>group.value));
    const ensAmount=weightedAverage(ensAmountFamilies,'value');
    const expectedPrecipitation = ensAmount == null ? (detMedian ?? 0)
      : detMedian == null ? ensAmount
      : 0.68*ensAmount + 0.32*detMedian;

    const familyOpinions=new Map();
    for(const group of detWetFamilies){
      const arr=familyOpinions.get(group.family)||[];arr.push(group.value);familyOpinions.set(group.family,arr);
    }
    for(const group of ensProbFamilies){
      const arr=familyOpinions.get(group.family)||[];arr.push(group.value);familyOpinions.set(group.family,arr);
    }
    const detByFamily=new Map(detWetFamilies.map(group=>[group.family,group.value]));
    const ensByFamily=new Map(ensProbFamilies.map(group=>[group.family,group.value]));
    const internalConflicts=[...detByFamily.entries()]
      .filter(([family])=>ensByFamily.has(family))
      .map(([family,detValue])=>Math.abs(Number(detValue)-Number(ensByFamily.get(family))))
      .filter(Number.isFinite);
    const internalFamilyDisagreement=internalConflicts.length
      ? internalConflicts.reduce((sum,value)=>sum+value,0)/internalConflicts.length
      : 0;
    const opinionVector=[...familyOpinions.values()].map(values=>values.reduce((s,v)=>s+v,0)/values.length);
    const spread=standardDeviation(opinionVector) ?? 0.5;
    const externalAgreement=clamp(1-spread/0.5);
    const agreement=clamp(externalAgreement*(1-.35*internalFamilyDisagreement));
    const providerCount=detAtTime.length+ensAtTime.length;
    const allFamilies=new Set([...deterministic,...ensembles].map(model=>model.family||model.id||model.label).filter(Boolean));
    const independentFamilyCount=familyOpinions.size;
    const familyTarget=Math.max(1,allFamilies.size);
    const coverage=clamp(independentFamilyCount/familyTarget);
    const horizonFactor=clamp(1-horizonHours/96);
    const evidenceFactor=clamp(independentFamilyCount/5);
    const rawTimingConfidence=clamp(0.15+0.36*agreement+0.20*coverage+0.14*horizonFactor+0.15*evidenceFactor);
    const horizonCap=horizonHours<=2?.96:horizonHours<=6?.92:horizonHours<=24?.84:horizonHours<=48?.76:.68;
    const familyEvidenceCap=independentFamilyCount>=6?.94
      : independentFamilyCount===5?.90
        : independentFamilyCount===4?.84
          : independentFamilyCount===3?.74
            : independentFamilyCount===2?.60
              : independentFamilyCount===1?.44
                :.25;
    const timingConfidence=Math.min(rawTimingConfidence,horizonCap,familyEvidenceCap);

    return {
      time,
      probability:clamp(probability),
      expectedPrecipitation:Math.max(0,expectedPrecipitation||0),
      agreement,
      externalAgreement,
      internalFamilyDisagreement,
      timingConfidence,
      providerCount,
      independentFamilyCount,
      deterministicCount:detAtTime.length,
      ensembleCount:ensAtTime.length,
    };
  });
}

function classifyRainHour(point={},{
  minimumProbability=.48,
  minimumExpected=.06,
  strongProbability=.64,
  strongExpected=.035,
  veryStrongProbability=.78,
  veryStrongExpected=.02,
  heavyExpected=.35,
  possibleProbability=.36,
  possibleExpected=.02
}={}){
  const probability=Math.max(0,Number(point.probability)||0);
  const expected=Math.max(0,Number(point.expectedPrecipitation)||0);
  const families=Number(point.independentFamilyCount);
  const singleFamily=Number.isFinite(families)&&families===1;
  const wetSignal=
    (probability>=minimumProbability&&expected>=minimumExpected)||
    (probability>=strongProbability&&expected>=strongExpected)||
    (probability>=veryStrongProbability&&expected>=veryStrongExpected)||
    expected>=heavyExpected;
  const singleFamilyStrong=expected>=heavyExpected||(probability>=.90&&expected>=.15);
  const wet=wetSignal&&(!singleFamily||singleFamilyStrong);
  if(wet)return'wet';
  const possible=
    wetSignal||
    (probability>=possibleProbability&&expected>=possibleExpected)||
    (probability>=.58&&expected>=.012)||
    expected>=.15;
  return possible?'possible':'dry';
}

function bridgeOnlyCredibleSingleHourGaps(points,states){
  const out=[...states];
  for(let i=1;i<states.length-1;i++){
    if(states[i]!=='possible'||states[i-1]!=='wet'||states[i+1]!=='wet')continue;
    const gap=points[i],left=points[i-1],right=points[i+1];
    const gapP=Number(gap.probability)||0,gapE=Number(gap.expectedPrecipitation)||0;
    const neighborAmount=Math.min(Number(left.expectedPrecipitation)||0,Number(right.expectedPrecipitation)||0);
    if(gapP>=.46&&gapE>=.035&&neighborAmount>=.10)out[i]='wet';
  }
  return out;
}

function findBoundaryWindow(points,index,direction,low=0.22,high=0.66){
  const start=points[index]?.time??null;
  if(!start) return {earliest:null,latest:null};
  let earliestIndex=index,latestIndex=index;
  if(direction==='start'){
    while(earliestIndex>0&&points[earliestIndex-1].probability>=low) earliestIndex--;
    while(latestIndex<points.length-1&&points[latestIndex].probability<high) latestIndex++;
    latestIndex=Math.min(latestIndex,index+2);
  }else{
    while(earliestIndex>0&&points[earliestIndex-1].probability>=high) earliestIndex--;
    while(latestIndex<points.length-1&&points[latestIndex+1].probability>=low) latestIndex++;
    latestIndex=Math.min(points.length-1,latestIndex+1);
  }
  return {earliest:points[earliestIndex]?.time??start,latest:points[latestIndex]?.time??start};
}

function detectRainEvents(points=[],options={}){
  if(!points.length) return [];
  const states=bridgeOnlyCredibleSingleHourGaps(points,points.map(point=>classifyRainHour(point,options)));
  const events=[];let i=0;
  while(i<points.length){
    if(states[i]!=='wet'){i++;continue}
    const startIndex=i;
    while(i+1<points.length&&states[i+1]==='wet') i++;
    const endIndex=i,segment=points.slice(startIndex,endIndex+1);
    const peakProbabilityRow=segment.reduce((best,row)=>row.probability>best.probability?row:best,segment[0]);
    const peakAmountRow=segment.reduce((best,row)=>row.expectedPrecipitation>best.expectedPrecipitation?row:best,segment[0]);
    const totalExpected=segment.reduce((sum,row)=>sum+(Number(row.expectedPrecipitation)||0),0);
    const meanExpected=totalExpected/Math.max(1,segment.length);
    const meanProbability=segment.reduce((sum,row)=>sum+(Number(row.probability)||0),0)/Math.max(1,segment.length);
    const meanTimingConfidence=segment.reduce((sum,row)=>sum+(Number(row.timingConfidence)||0),0)/Math.max(1,segment.length);
    const meanInternalDisagreement=segment.reduce((sum,row)=>sum+(Number(row.internalFamilyDisagreement)||0),0)/Math.max(1,segment.length);
    const variance=segment.reduce((sum,row)=>sum+((Number(row.expectedPrecipitation)||0)-meanExpected)**2,0)/Math.max(1,segment.length);
    const variation=meanExpected>0?Math.sqrt(variance)/meanExpected:0;
    const durationHours=endIndex-startIndex+1;
    const character=durationHours>=5&&variation<.45?'persistente':variation>.8?'por pulsos':'variable';
    const horizonHours=Math.max(0,(Date.parse(points[startIndex].time)-Date.now())/3_600_000);
    const horizonPadding=horizonHours<6?1:horizonHours<24?2:3;
    const confidencePadding=meanTimingConfidence<.45?2:meanTimingConfidence<.65?1:0;
    const windowPadding=Math.max(0,horizonPadding-1)+confidencePadding;
    const startWindow=findBoundaryWindow(points,startIndex,'start',.28,.70);
    const endWindow=findBoundaryWindow(points,endIndex,'end',.28,.70);
    if(startWindow.earliest&&startWindow.latest){
      startWindow.earliest=new Date(Date.parse(startWindow.earliest)-windowPadding*3_600_000).toISOString();
      startWindow.latest=new Date(Date.parse(startWindow.latest)+windowPadding*3_600_000).toISOString();
    }
    if(endWindow.earliest&&endWindow.latest&&windowPadding>0){
      endWindow.earliest=new Date(Date.parse(endWindow.earliest)-windowPadding*3_600_000).toISOString();
      endWindow.latest=new Date(Date.parse(endWindow.latest)+windowPadding*3_600_000).toISOString();
    }
    const likelyEndMs=Date.parse(points[endIndex].time)+3_600_000;
    events.push({
      start:points[startIndex].time,
      end:new Date(likelyEndMs).toISOString(),
      startWindow,endWindow,
      peakTime:peakProbabilityRow.time,
      peakProbability:peakProbabilityRow.probability,
      peakExpectedTime:peakAmountRow.time,
      maxExpectedPrecipitation:Number(peakAmountRow.expectedPrecipitation)||0,
      averageExpectedPrecipitation:meanExpected,
      averageProbability:meanProbability,
      totalExpectedPrecipitation:totalExpected,
      timingConfidence:meanTimingConfidence,
      internalFamilyDisagreement:meanInternalDisagreement,
      durationHours,
      character,
      providerCount:Math.max(...segment.map(row=>row.providerCount||0)),
      independentFamilyCount:Math.max(...segment.map(row=>row.independentFamilyCount||0)),
    });
    i++;
  }
  return events;
}

function detectQuarterHourEvents(time=[],precipitation=[],threshold=0.03){
  if(!Array.isArray(time)||!Array.isArray(precipitation)) return [];
  const events=[];let i=0;
  while(i<time.length){
    const value=Number(precipitation[i]);
    if(!Number.isFinite(value)||value<threshold){i++;continue}
    const startIndex=i;
    while(i+1<time.length&&Number(precipitation[i+1])>=threshold) i++;
    const endIndex=i,segment=precipitation.slice(startIndex,endIndex+1).map(Number).filter(Number.isFinite);
    events.push({start:time[startIndex],end:new Date(Date.parse(time[endIndex])+15*60_000).toISOString(),max:Math.max(...segment),total:segment.reduce((s,v)=>s+v,0)});
    i++;
  }
  return events;
}

function compactTimeline(points=[],limit=72){
  return points.slice(0,limit).map(row=>({
    time:row.time,
    probability:Math.round(row.probability*100),
    precipitation:Number(row.expectedPrecipitation.toFixed(2)),
    confidence:Math.round(row.timingConfidence*100),
    agreement:Math.round(row.agreement*100),
    internalDisagreement:Math.round((Number(row.internalFamilyDisagreement)||0)*100),
    independentFamilies:row.independentFamilyCount||0,
  }));
}

function chooseNextEvent(events=[],nowMs=Date.now()){
  return events.find(e=>Date.parse(e.end)>nowMs)||null;
}

function bestDryWindow(events=[],nowMs=Date.now(),horizonEndMs=nowMs+24*3_600_000,{minMinutes=30}={}){
  const start=Math.max(0,Number(nowMs)||0),end=Math.max(start,Number(horizonEndMs)||start);
  const wet=(events||[])
    .map(e=>({start:Date.parse(e.start),end:Date.parse(e.end)}))
    .filter(e=>Number.isFinite(e.start)&&Number.isFinite(e.end)&&e.end>start&&e.start<end)
    .map(e=>({start:Math.max(start,e.start),end:Math.min(end,e.end)}))
    .sort((a,b)=>a.start-b.start);
  const merged=[];
  for(const e of wet){
    const last=merged.at(-1);
    if(last&&e.start<=last.end+5*60_000)last.end=Math.max(last.end,e.end);
    else merged.push({...e});
  }
  const dry=[];let cursor=start;
  for(const e of merged){
    if(e.start>cursor)dry.push({start:cursor,end:e.start});
    cursor=Math.max(cursor,e.end);
  }
  if(cursor<end)dry.push({start:cursor,end});
  const eligible=dry
    .map(w=>({...w,minutes:Math.max(0,Math.round((w.end-w.start)/60_000))}))
    .filter(w=>w.minutes>=minMinutes);
  if(!eligible.length)return null;
  return eligible.reduce((best,w)=>!best||w.minutes>best.minutes||(w.minutes===best.minutes&&w.start<best.start)?w:best,null);
}


/*
 * RainETA consensus mobile adapter
 * SAME aggregateEnsembleModel(), buildConsensus(), detectRainEvents()
 * as vercel-webhook/rain/core.js (source branch head PR #98).
 * Radar advection/AEMET HARMONIE are NOT executed in Scriptable.
 */
const RA_DET_MODELS=[
  {id:'ecmwf_ifs',label:'ECMWF IFS',family:'ECMWF',weight:1.32,kind:'det'},
  {id:'icon_seamless',label:'DWD ICON',family:'DWD',weight:1.10,kind:'det'},
  {id:'meteofrance_seamless',label:'Météo-France ARPEGE',family:'METEOFRANCE',weight:1.0,kind:'det'},
  {id:'ukmo_global_deterministic_10km',label:'UKMO Global',family:'UKMO',weight:1.02,kind:'det'},
  {id:'dwd_icon_eu_eps',label:'ICON-EU EPS',family:'DWD',weight:1.10,kind:'ens'},
  {id:'ncep_gefs025',label:'NOAA GEFS',family:'NOAA',weight:.90,kind:'ens'},
  {id:'ecmwf_aifs025_ensemble',label:'ECMWF AIFS ENS',family:'ECMWF',weight:1.00,kind:'ens'}
];
function forecastUrl(model,loc){
  const root=model.kind==='ens'?'https://ensemble-api.open-meteo.com/v1/ensemble':
    'https://api.open-meteo.com/v1/forecast';
  const q='latitude='+encodeURIComponent(loc.lat)+'&longitude='+encodeURIComponent(loc.lon)+
    '&hourly=precipitation&forecast_hours=18&timeformat=unixtime&timezone=GMT'+
    '&models='+encodeURIComponent(model.id);
  return root+'?'+q;
}
function normaliseTimestamp(time){
  const parsed=typeof time==='number'?time*1000:Date.parse(time);
  return Number.isFinite(parsed)?new Date(parsed).toISOString():null;
}
function parseRainetaModel(model,body){
  if(!body||body.error===true)throw Error(String(body?.reason||'Modelo no disponible'));
  const hourly=body.hourly||{},times=Array.isArray(hourly.time)?hourly.time:[];
  if(!times.length)throw Error('Sin horas '+model.id);
  if(model.kind==='det'){
    const amounts=hourly.precipitation;
    if(!Array.isArray(amounts))throw Error('Sin precipitación '+model.id);
    const rows=times.map((t,i)=>({time:normaliseTimestamp(t),precipitation:amounts[i]==null?null:Number(amounts[i])}))
      .filter(x=>x.time!==null&&x.precipitation!==null&&Number.isFinite(x.precipitation));
    if(rows.length<8)throw Error('Sin predicción suficiente '+model.id);
    return {...model,rows};
  }
  const source={...hourly,time:times.map(normaliseTimestamp)};
  const ensemble=aggregateEnsembleModel(source);
  if(!ensemble||ensemble.memberCount<3)throw Error('Conjunto insuficiente '+model.id);
  return {...model,rows:ensemble.rows.filter(x=>x.time&&Number.isFinite(Number(x.probability))),memberCount:ensemble.memberCount};
}
function signalHours(timeline,now){
  return timeline.filter(row=>{
    const end=Date.parse(row.time);
    return Number.isFinite(end)&&end>now&&end<=now+13*3600000;
  }).slice(0,12).map(row=>{
    const end=Date.parse(row.time);
    return {start:end-3600000,end,
      probability:Math.round(Math.max(0,Math.min(1,row.probability))*100),
      mm:Math.round(Math.max(0,row.expectedPrecipitation)*10)/10,
      confidence:Math.round(Math.max(0,Math.min(1,row.timingConfidence))*100)};
  });
}
function rainetaConsensusOutput(deterministic,ensembles,current,now){
  const timeline=buildConsensus({deterministic,ensembles,nowMs:now});
  if(!timeline.length)throw Error('Consenso vacío');
  const hours=signalHours(timeline,now);
  if(!hours.length)throw Error('Sin horas previstas');
  // Open-Meteo hourly precipitation belongs to the preceding hour. Translate
  // interval end -> start before detecting onset/cessation, without changing
  // RainETA's original consensus/event-detection functions.
  const intervalRows=timeline.map(row=>({...row,time:new Date(Date.parse(row.time)-3600000).toISOString()}));
  const events=detectRainEvents(intervalRows);
  const next=chooseNextEvent(events,now);
  // "Current" is model analysis, not a rain-gauge observation or radar detection.
  const curr=current?.current||{};
  const v=curr.precipitation==null?NaN:Number(curr.precipitation);
  const currentRain=Number.isFinite(v)&&v>=0.12;
  const active=Boolean(next)&&Date.parse(next.start)<=now&&Date.parse(next.end)>now;
  const phase=currentRain||active?'raining':'dry';
  let target=null,action='none';
  if(phase==='raining'){
    if(active&&Number.isFinite(Date.parse(next.end))){
      target=Date.parse(next.end);action='stops';
    }
  }else if(next&&Number.isFinite(Date.parse(next.start))&&Date.parse(next.start)>now){
    target=Date.parse(next.start);action='starts';
  }
  const eventWithin12h=target!==null&&target<=now+12*3600000;
  if(!eventWithin12h){target=null;action='none';}
  const confident=Number(next?.timingConfidence)||0;
  const sources=[...deterministic,...ensembles];
  const families=[...new Set(sources.map(s=>s.family))];
  return {ok:true,phase,action,targetAt:target?new Date(target).toISOString():null,
    precisionMinutes:60,
    confidence:confident>=.7?'media':'baja',
    summary:phase==='raining'?'Lluvia señalada por modelo; fin incierto':
      'Sin episodio de lluvia firme en las próximas 12 h',
    hours,updatedAt:now,fromCache:false,
    generatedAt:new Date(now).toISOString(),modelCount:sources.length,familyCount:families.length,
    deterministicCount:deterministic.length,ensembleCount:ensembles.length,
    names:sources.map(s=>s.label),radarIncluded:false,
    caveat:'RainETA consenso horario sin nowcast radar'};
}
async function rainForecast(pos){
  // Independent providers are requested in parallel; failures are reported rather
  // than silently counted as dry votes.
  const requests=RA_DET_MODELS.map(async model=>
    parseRainetaModel(model,await getJson(forecastUrl(model,pos))));
  const baseUrl='https://api.open-meteo.com/v1/forecast?latitude='+
    encodeURIComponent(pos.lat)+'&longitude='+encodeURIComponent(pos.lon)+
    '&current=precipitation&forecast_hours=1&timeformat=unixtime&timezone=GMT';
  const all=await Promise.allSettled([...requests,getJson(baseUrl)]);
  const successful=all.slice(0,RA_DET_MODELS.length)
    .filter(item=>item.status==='fulfilled').map(item=>item.value);
  if(successful.length<2)throw Error('No hay suficientes modelos disponibles');
  const deterministic=successful.filter(m=>m.kind==='det');
  const ensembles=successful.filter(m=>m.kind==='ens');
  const current=all[all.length-1].status==='fulfilled'?all[all.length-1].value:null;
  return rainetaConsensusOutput(deterministic,ensembles,current,Date.now());
}


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

async function freshOrCache(pos){
  try{
    const value=await rainForecast(pos);
    if(!value.ok)throw Error('Previsión incompleta');
    try{Keychain.set(CACHE_KEY,JSON.stringify({lat:pos.lat,lon:pos.lon,value}))}catch(_){}
    return value;
  }catch(error){
    try{
      if(Keychain.contains(CACHE_KEY)){
        const saved=JSON.parse(Keychain.get(CACHE_KEY));
        const age=Date.now()-Number(saved.value?.updatedAt||0);
        if(Math.abs(saved.lat-pos.lat)<0.02&&Math.abs(saved.lon-pos.lon)<0.02&&age>=0&&age<120*60000)
          return {...saved.value,fromCache:true};
      }
    }catch(_){}
    throw error;
  }
}
const widget=new ListWidget();
widget.backgroundColor=new Color('#0a2032');
widget.setPadding(SMALL?13:8,SMALL?12:8,SMALL?12:8,SMALL?12:8);
widget.spacing=0;
function label(str,size,color,bold=false){
  const t=widget.addText(str);
  t.font=bold?Font.boldSystemFont(size):Font.systemFont(size);
  t.textColor=new Color(color);t.lineLimit=2;
  return t;
}
try{
  const place=await position();
  const observationPromise=radarObservadoAt(place);
  const d=await freshOrCache(place);
  const obs=await observationPromise;
  const now=Date.now(),ageMin=Math.max(0,Math.floor((now-d.updatedAt)/60000));
  label('RainETA CONSENSO · '+place.name,SMALL?10:11,'#89d2f6',true);
  label(radarObsLabel(obs),SMALL?9:10,
    obs.status==='echo'?'#a6e9fd':obs.status==='clear'?'#bad5e1':'#ffd09b',true);
  widget.addSpacer(SMALL?8:2);
  const target=d.targetAt?new Date(d.targetAt):null;
  const upcoming=target&&Number.isFinite(target.getTime())&&target.getTime()>now&&d.action!=='none';
  const stale=d.fromCache&&ageMin>35;
  if(stale){
    label('Datos guardados antiguos',SMALL?12:16,'#ffd09b',true);
    if(SMALL)label('Sin ETA fiable',11,'#c9e0ed');
  }else if(upcoming){
    if(SMALL){
      label(d.action==='starts'?'EMPIEZA EN':'FIN MODELO EN',10,'#c6e5f5',true);
      const timer=widget.addDate(target);
      timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(31);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.5;
      label('±'+(d.precisionMinutes||60)+' min · modelos, sin radar',9,'#a2c6db');
    }else{
      const stack=widget.addStack();
      stack.layoutHorizontally();stack.centerAlignContent();
      const prefix=stack.addText(d.action==='starts'?'Empieza en ':'Fin modelo en ');
      prefix.font=Font.systemFont(13);prefix.textColor=new Color('#dceffa');
      const timer=stack.addDate(target);timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(LARGE?29:23);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.6;
    }
    if(LARGE)label('Hora estimada '+hhmm(target.getTime())+' · margen ±'+(d.precisionMinutes||60)+' min · SIN RADAR',10,'#a9cedf');
  }else{
    label(d.phase==='raining'?'Modelo señala lluvia':'Modelos: sin lluvia cercana',SMALL?16:18,'#ffffff',true);
    if(SMALL)label(d.summary,10,'#b3ccda');
  }
  if(!SMALL){
    widget.addSpacer(LARGE?12:3);
    label('12 H · % CONSENSO / MM PREVISTOS',LARGE?11:9,'#b6d6ec',true);
    widget.addSpacer(2);
    const hours=Array.isArray(d.hours)?d.hours:[];
    if(hours.length){
      const chart=widget.addImage(drawRainBars(hours,LARGE));
      const width=LARGE?312:300;
      chart.imageSize=new Size(width,width*(LARGE?252:210)/720);
      chart.centerAlignImage();chart.applyFittingContentMode();
      if(LARGE){
        widget.addSpacer(9);
        label('Cada barra: inicio hora abajo · % modelo arriba · lluvia mm/h',10,'#b2ccdc');
        label('Celeste: débil  Azul: moderada  Violeta: fuerte  Coral: intensa',10,'#b2ccdc');
      }
    }else{
      label('Probabilidad horaria no disponible',11,'#ffd09b');
    }
  }
  widget.addSpacer();
  const updateText=(d.fromCache?'Guardado ':'Actualizado ')+hhmm(d.updatedAt);
  label(updateText+' · '+d.modelCount+'M/'+d.familyCount+'F · Open-Meteo.com',9,'#8eafc4');
  widget.refreshAfterDate=new Date(now+(d.fromCache?5:REFRESH_MINUTES)*60000);
}catch(error){
  widget.addSpacer(9);
  label('No se pudo actualizar',15,'#ffffff',true);
  widget.addSpacer(5);
  label(String(error.message||error).slice(0,116),10,'#c6dce8');
  widget.refreshAfterDate=new Date(Date.now()+5*60000);
}
Script.setWidget(widget);
if(!config.runsInWidget){
  if(LARGE)await widget.presentLarge();
  else await widget.presentMedium();
}
Script.complete();
