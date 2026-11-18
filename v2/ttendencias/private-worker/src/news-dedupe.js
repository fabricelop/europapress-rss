// V1 second deduplication barrier for the private V2 lists.
// This is presentation-only: original IDs, decisions, job records and
// publication history remain immutable and individually recoverable.
const WINDOW=48*60*60*1000;
function key(title){
 const value=String(title||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"")
  .toLowerCase().replace(/[^a-z0-9ñ]+/g," ").trim().replace(/\s+/g," ");
 if(!value||/^(?:ultima hora|en directo|noticias de hoy|actualidad politica)(?: |$)/.test(value))return null;
 return value;
}
function rank(row){
 return ({ready:6,working:5,pending:4,incident:3,archived:2,detected:1})[row.group]||0;
}
export function dedupeNewsRows(rows,originalRows,controls={}){
 const prefs=new Map((controls.preferences||[]).map(x=>[x.event_id+":"+x.revision,x]));
 const terminal=new Map(),chosen=new Map(),visible=[];
 for(const row of originalRows){
  const pref=prefs.get(row.event_id+":"+row.revision)||{};
  if(pref.dismissed!==true&&pref.incident_hidden!==true&&pref.archived!==true)continue;
  const k=key(row.title),time=Date.parse(row.first_seen_at);
  if(!k||!Number.isFinite(time))continue;
  const times=terminal.get(k)||[];
  times.push(time);terminal.set(k,times);
 }
 for(const row of rows){
  const k=key(row.title),time=Date.parse(row.first_seen_at);
  if(!k||!Number.isFinite(time)||row.group==="detected"){visible.push(row);continue;}
  if(row.group!=="archived"&&(terminal.get(k)||[]).some(at=>Math.abs(time-at)<=WINDOW))
   continue;
  const matches=chosen.get(k)||[];
  const match=matches.find(x=>Math.abs(x.time-time)<=WINDOW);
  if(!match){
   matches.push({time,row,index:visible.length});chosen.set(k,matches);visible.push(row);
  }else if(rank(row)>rank(match.row)){
   visible[match.index]=row;
   match.row=row;match.time=time;
  }
 }
 return visible;
}
