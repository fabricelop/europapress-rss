export const WET_THRESHOLD_MM = 0.1;

export function clamp(value, min = 0, max = 1) {
  return Math.min(max, Math.max(min, Number.isFinite(value) ? value : min));
}

export function median(values) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!clean.length) return null;
  const mid = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[mid] : (clean[mid - 1] + clean[mid]) / 2;
}

export function percentile(values, p) {
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

export function aggregateEnsembleModel(hourly = {}, wetThreshold = WET_THRESHOLD_MM) {
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
  return { memberCount: memberKeys.length, rows };
}

export function buildConsensus({ deterministic = [], ensembles = [], nowMs = Date.now() }) {
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
    const opinionVector=[...familyOpinions.values()].map(values=>values.reduce((s,v)=>s+v,0)/values.length);
    const spread=standardDeviation(opinionVector) ?? 0.5;
    const agreement=clamp(1-spread/0.5);
    const providerCount=detAtTime.length+ensAtTime.length;
    const allFamilies=new Set([...deterministic,...ensembles].map(model=>model.family||model.id||model.label).filter(Boolean));
    const independentFamilyCount=familyOpinions.size;
    const familyTarget=Math.max(1,allFamilies.size);
    const coverage=clamp(independentFamilyCount/familyTarget);
    const horizonFactor=clamp(1-horizonHours/96);
    const evidenceFactor=clamp(independentFamilyCount/5);
    const rawTimingConfidence=clamp(0.15+0.36*agreement+0.20*coverage+0.14*horizonFactor+0.15*evidenceFactor);
    const horizonCap=horizonHours<=2?.96:horizonHours<=6?.92:horizonHours<=24?.84:horizonHours<=48?.76:.68;
    const timingConfidence=Math.min(rawTimingConfidence,horizonCap);

    return {
      time,
      probability:clamp(probability),
      expectedPrecipitation:Math.max(0,expectedPrecipitation||0),
      agreement,
      timingConfidence,
      providerCount,
      independentFamilyCount,
      deterministicCount:detAtTime.length,
      ensembleCount:ensAtTime.length,
    };
  });
}

export function classifyRainHour(point={},{
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
  const wet=
    (probability>=minimumProbability&&expected>=minimumExpected)||
    (probability>=strongProbability&&expected>=strongExpected)||
    (probability>=veryStrongProbability&&expected>=veryStrongExpected)||
    expected>=heavyExpected;
  if(wet)return'wet';
  const possible=
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

export function detectRainEvents(points=[],options={}){
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
    const variance=segment.reduce((sum,row)=>sum+((Number(row.expectedPrecipitation)||0)-meanExpected)**2,0)/Math.max(1,segment.length);
    const variation=meanExpected>0?Math.sqrt(variance)/meanExpected:0;
    const durationHours=endIndex-startIndex+1;
    const character=durationHours>=5&&variation<.45?'persistente':variation>.8?'por pulsos':'variable';
    const horizonHours=Math.max(0,(Date.parse(points[startIndex].time)-Date.now())/3_600_000);
    const horizonPadding=horizonHours<6?1:horizonHours<24?2:3;
    const startWindow=findBoundaryWindow(points,startIndex,'start',.28,.70);
    const endWindow=findBoundaryWindow(points,endIndex,'end',.28,.70);
    if(startWindow.earliest&&startWindow.latest){
      startWindow.earliest=new Date(Date.parse(startWindow.earliest)-Math.max(0,horizonPadding-1)*3_600_000).toISOString();
      startWindow.latest=new Date(Date.parse(startWindow.latest)+Math.max(0,horizonPadding-1)*3_600_000).toISOString();
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
      durationHours,
      character,
      providerCount:Math.max(...segment.map(row=>row.providerCount||0)),
      independentFamilyCount:Math.max(...segment.map(row=>row.independentFamilyCount||0)),
    });
    i++;
  }
  return events;
}

export function detectQuarterHourEvents(time=[],precipitation=[],threshold=0.03){
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

export function compactTimeline(points=[],limit=72){
  return points.slice(0,limit).map(row=>({
    time:row.time,
    probability:Math.round(row.probability*100),
    precipitation:Number(row.expectedPrecipitation.toFixed(2)),
    confidence:Math.round(row.timingConfidence*100),
    agreement:Math.round(row.agreement*100),
    independentFamilies:row.independentFamilyCount||0,
  }));
}

export function chooseNextEvent(events=[],nowMs=Date.now()){
  return events.find(e=>Date.parse(e.end)>nowMs)||null;
}
