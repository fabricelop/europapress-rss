const $=s=>document.querySelector(s);let prepared={items:[]},status={},active=null,view='ready',runPoll=null;
async function json(p){const r=await fetch(p+'?t='+Date.now(),{cache:'no-store'});if(!r.ok)throw Error(p);return r.json()}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function when(s){return s?new Date(s).toLocaleTimeString('es-ES',{hour:'2-digit',minute:'2-digit'}):''}
function duration(s){if(s==null||!Number.isFinite(+s))return '';s=+s;if(s<60)return s+' s';return Math.floor(s/60)+' min '+(s%60)+' s'}
async function load(){try{[prepared,status]=await Promise.all([json('./prepared.json'),json('./status.json')]);render()}catch(e){$('#stamp').textContent='Error al actualizar'}}
function setView(v){view=v;document.querySelectorAll('.stat').forEach(b=>b.classList.toggle('active',b.dataset.view===v));renderList()}
function render(){const items=prepared.items||[];$('#ready').textContent=items.length;$('#processing').textContent=status.processing_count??0;$('#stamp').textContent='Actualizado '+when(status.updated_at||prepared.updated_at||Date.now());const ok=status.healthy_source_count??'–',total=status.configured_sources??'–',h=$('#health');h.textContent='Fuentes: '+ok+'/'+total+' funcionando';h.classList.toggle('bad',Number.isFinite(+ok)&&Number.isFinite(+total)&&+ok<+total);renderList()}
function renderList(){const list=$('#list');list.innerHTML='';if(view==='processing'){renderProcessing(list);return}renderReady(list)}
function renderReady(list){$('#viewTitle').textContent='Noticias listas';$('#viewHelp').textContent='Solo entran noticias con al menos 4 fuentes. Ordenadas por número actual de fuentes y después por recencia.';
 const items=[...(prepared.items||[])].sort((a,b)=>{const ac=status.events?.[a.event_id]?.source_count||a.drafted_source_count||0,bc=status.events?.[b.event_id]?.source_count||b.drafted_source_count||0;return bc-ac||String(b.prepared_at||'').localeCompare(String(a.prepared_at||''))});
 if(!items.length){list.innerHTML='<div class="empty">No hay noticias redactadas pendientes.</div>';return}
 for(const x of items){const n=$('#card').content.cloneNode(true),card=n.querySelector('.card'),cur=status.events?.[x.event_id]?.source_count??x.drafted_source_count??0,draft=x.drafted_source_count??cur;n.querySelector('.title').textContent=x.title||'Sin titular';n.querySelector('.meta').textContent='Redactada con '+draft+' ('+cur+') · '+when(x.prepared_at);n.querySelector('.facts').textContent=x.factual_summary||'';const vs=n.querySelector('.variants');for(const v of x.variants||[]){const d=document.createElement('div');d.className='variant';d.innerHTML='<strong>'+esc(v.label||'Opción')+'</strong><p>'+esc(v.text||'')+'</p><a target="_blank" rel="noopener" href="'+esc(v.url||'#')+'">Publicar en X</a>';vs.appendChild(d)}n.querySelector('.summary').onclick=()=>card.classList.toggle('open');n.querySelectorAll('[data-act]').forEach(b=>b.onclick=()=>act(b.dataset.act,x));list.appendChild(n)}
}
function renderProcessing(list){$('#viewTitle').textContent='En elaboración';$('#viewHelp').textContent='Noticias que ya alcanzaron 4 fuentes y están esperando o pasando por el pase editorial.';
 const items=status.processing_items||[];if(!items.length){list.innerHTML='<div class="empty">No hay noticias en elaboración.</div>';return}
 for(const x of items){list.appendChild(queueCard(x))}
}
function queueCard(x){const a=document.createElement('article');a.className='queuecard';const chips=(x.sources||[]).map(s=>'<span class="chip">'+esc(typeof s==='string'?s:(s.name||s.source||''))+'</span>').join('');a.innerHTML='<h3>'+esc(x.title||'Sin titular')+'</h3><p>'+esc((x.source_count||0)+' fuentes · entrada '+when(x.selected_at))+'</p><div class="chips">'+chips+'</div>'+(x.url?'<p><a class="source-link" target="_blank" rel="noopener" href="'+esc(x.url)+'">Abrir noticia base</a></p>':'');return a}
async function act(action,x){if(action==='rewrite'){active=x;$('#rewriteText').value='';$('#rewriteDlg').showModal();return}await send(action,x,'')}
async function send(action,x,instructions){const r=await fetch('/api/ttittulares-control',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,event_id:x.event_id,instructions})});if(!r.ok){alert('No se pudo guardar la acción');return}await load()}
function runKey(){return localStorage.getItem('ttittularesRunKey')||''}
function runVisual(s){
 const el=$('#runState'),btn=$('#runNow');el.className='';btn.disabled=false;
 if(!s||s.status==='IDLE'){el.textContent=runKey()?'Listo para ejecutar':'Disponible · pedirá clave al primer uso';return}
 if(s.status==='REQUESTED'){el.textContent='Solicitada '+when(s.requested_at)+' · esperando a Work';el.className='running';btn.disabled=true;return}
 if(s.status==='RUNNING'){el.textContent='Ejecutándose desde '+when(s.started_at)+(s.start_delay_seconds!=null?' · arrancó en '+duration(s.start_delay_seconds):'');el.className='running';btn.disabled=true;return}
 if(s.status==='DONE'){el.textContent='Terminada '+when(s.finished_at)+(s.start_delay_seconds!=null?' · arranque '+duration(s.start_delay_seconds):'')+(s.duration_seconds!=null?' · duración '+duration(s.duration_seconds):'');el.className='done';return}
 if(s.status==='ERROR'){el.textContent='Error '+when(s.finished_at)+(s.message?' · '+s.message:'');el.className='error';return}
 el.textContent=s.status||'Estado desconocido'
}
async function loadRunStatus(){
 const key=runKey();if(!key){runVisual({status:'IDLE'});scheduleRunPoll(false);return}
 try{
  const r=await fetch('/api/ttittulares-run-status?t='+Date.now(),{cache:'no-store',headers:{'x-tt-run-key':key}});
  if(r.status===401){localStorage.removeItem('ttittularesRunKey');runVisual({status:'IDLE'});scheduleRunPoll(false);return}
  if(r.status===503){$('#runState').textContent='Preparado en código · falta configurar trigger';$('#runNow').disabled=true;scheduleRunPoll(false);return}
  if(!r.ok)throw Error('status');
  const s=await r.json();runVisual(s);scheduleRunPoll(['REQUESTED','RUNNING'].includes(s.status));
 }catch(_){$('#runState').textContent='No se pudo consultar el estado';$('#runState').className='error';scheduleRunPoll(false)}
}
function scheduleRunPoll(fast){
 clearTimeout(runPoll);runPoll=setTimeout(loadRunStatus,fast?5000:60000)
}
async function requestRun(){
 if(!confirm('¿Ejecutar TTiTTulares ahora? Esta acción consumirá cuota de ChatGPT Work.'))return;
 let key=runKey();
 if(!key){key=(prompt('Clave privada de “Ejecutar ahora”')||'').trim();if(!key)return;localStorage.setItem('ttittularesRunKey',key)}
 const btn=$('#runNow');btn.disabled=true;$('#runState').textContent='Enviando solicitud…';$('#runState').className='running';
 try{
  const r=await fetch('/api/ttittulares-run',{method:'POST',headers:{'content-type':'application/json','x-tt-run-key':key},body:'{}'});
  const j=await r.json().catch(()=>({}));
  if(r.status===401){localStorage.removeItem('ttittularesRunKey');throw Error('Clave incorrecta; se ha borrado del navegador')}
  if(r.status===429)throw Error('Ya hay una solicitud reciente. Prueba de nuevo en '+(j.retry_after_seconds||'unos')+' s')
  if(r.status===503)throw Error('El disparador todavía no está configurado')
  if(!r.ok)throw Error(j.detail||j.error||'No se pudo solicitar la ejecución');
  runVisual({status:'REQUESTED',requested_at:j.requested_at});scheduleRunPoll(true)
 }catch(e){$('#runState').textContent=String(e.message||e);$('#runState').className='error';btn.disabled=false}
}
$('#rewriteOk').onclick=async e=>{e.preventDefault();const t=$('#rewriteText').value.trim();if(!t)return;$('#rewriteDlg').close();await send('rewrite',active,t)};
document.querySelectorAll('.stat').forEach(b=>b.onclick=()=>setView(b.dataset.view));$('#refresh').onclick=()=>{load();loadRunStatus()};$('#runNow').onclick=requestRun;load();loadRunStatus();setInterval(load,60000);