const $=s=>document.querySelector(s);let prepared={items:[]},status={},active=null,view='ready';
async function json(p){const r=await fetch(p+'?t='+Date.now(),{cache:'no-store'});if(!r.ok)throw Error(p);return r.json()}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function when(s){return s?new Date(s).toLocaleTimeString('es-ES',{hour:'2-digit',minute:'2-digit'}):''}
async function load(){try{[prepared,status]=await Promise.all([json('./prepared.json'),json('./status.json')]);render()}catch(e){$('#stamp').textContent='Error al actualizar'}}
function setView(v){view=v;document.querySelectorAll('.stat').forEach(b=>b.classList.toggle('active',b.dataset.view===v));renderList()}
function render(){const items=prepared.items||[];$('#ready').textContent=items.length;$('#processing').textContent=status.processing_count??0;$('#three').textContent=status.three_sources_count??0;$('#stamp').textContent='Actualizado '+when(status.updated_at||prepared.updated_at||Date.now());$('#health').textContent=(status.healthy_source_count??'–')+' fuentes generales sanas';renderList()}
function renderList(){const list=$('#list');list.innerHTML='';
 if(view==='three'){renderThree(list);return}
 if(view==='processing'){renderProcessing(list);return}
 renderReady(list)
}
function renderReady(list){$('#viewTitle').textContent='Noticias listas';$('#viewHelp').textContent='Ordenadas por número actual de fuentes y, a igualdad, por recencia.';
 const items=[...(prepared.items||[])].sort((a,b)=>{const ac=status.events?.[a.event_id]?.source_count||a.drafted_source_count||0,bc=status.events?.[b.event_id]?.source_count||b.drafted_source_count||0;return bc-ac||String(b.prepared_at||'').localeCompare(String(a.prepared_at||''))});
 if(!items.length){list.innerHTML='<div class="empty">No hay noticias redactadas pendientes.</div>';return}
 for(const x of items){const n=$('#card').content.cloneNode(true),card=n.querySelector('.card'),cur=status.events?.[x.event_id]?.source_count??x.drafted_source_count??0,draft=x.drafted_source_count??cur;n.querySelector('.title').textContent=x.title||'Sin titular';n.querySelector('.meta').textContent='Redactada con '+draft+' ('+cur+') · '+when(x.prepared_at);n.querySelector('.facts').textContent=x.factual_summary||'';const vs=n.querySelector('.variants');for(const v of x.variants||[]){const d=document.createElement('div');d.className='variant';d.innerHTML='<strong>'+esc(v.label||'Opción')+'</strong><p>'+esc(v.text||'')+'</p><a target="_blank" rel="noopener" href="'+esc(v.url||'#')+'">Publicar en X</a>';vs.appendChild(d)}n.querySelector('.summary').onclick=()=>card.classList.toggle('open');n.querySelectorAll('[data-act]').forEach(b=>b.onclick=()=>act(b.dataset.act,x));list.appendChild(n)}
}
function renderProcessing(list){$('#viewTitle').textContent='En elaboración';$('#viewHelp').textContent='Noticias que ya alcanzaron el umbral y están esperando o pasando por el pase editorial.';
 const items=status.processing_items||[];if(!items.length){list.innerHTML='<div class="empty">No hay noticias en elaboración.</div>';return}
 for(const x of items){list.appendChild(queueCard(x,(x.source_count||0)+' fuentes · entrada '+when(x.selected_at),true))}
}
function renderThree(list){$('#viewTitle').textContent='Con 3 fuentes';$('#viewHelp').textContent='Se muestran tal cual las detecta el radar. Aún no se redactan: están a una fuente del umbral de 4.';
 const items=status.three_source_items||[];if(!items.length){list.innerHTML='<div class="empty">Ahora mismo no hay noticias exactamente con 3 fuentes.</div>';return}
 for(const x of items){list.appendChild(queueCard(x,'3 fuentes · última detección '+when(x.last_seen),false))}
}
function queueCard(x,processing){const a=document.createElement('article');a.className='queuecard';const chips=(x.sources||[]).map(s=>'<span class="chip">'+esc(typeof s==='string'?s:(s.name||s.source||''))+'</span>').join('');a.innerHTML='<h3>'+esc(x.title||'Sin titular')+'</h3><p>'+esc(processing?'En elaboración':'Pendiente de una cuarta fuente')+' · '+esc(processing?((x.source_count||0)+' fuentes · '+when(x.selected_at)):('última detección '+when(x.last_seen)))+'</p><div class="chips">'+chips+'</div>'+(x.url?'<p><a class="source-link" target="_blank" rel="noopener" href="'+esc(x.url)+'">Abrir fuente</a></p>':'');return a}
async function act(action,x){if(action==='rewrite'){active=x;$('#rewriteText').value='';$('#rewriteDlg').showModal();return}await send(action,x,'')}
async function send(action,x,instructions){const r=await fetch('/api/ttittulares-control',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,event_id:x.event_id,instructions})});if(!r.ok){alert('No se pudo guardar la acción');return}await load()}
$('#rewriteOk').onclick=async e=>{e.preventDefault();const t=$('#rewriteText').value.trim();if(!t)return;$('#rewriteDlg').close();await send('rewrite',active,t)};
document.querySelectorAll('.stat').forEach(b=>b.onclick=()=>setView(b.dataset.view));$('#refresh').onclick=load;load();setInterval(load,60000);