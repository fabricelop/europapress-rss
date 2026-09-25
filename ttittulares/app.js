const $=s=>document.querySelector(s);
let prepared={items:[]},status={},active=null,view='ready',runPoll=null;

async function json(p){
  const r=await fetch(p+'?t='+Date.now(),{cache:'no-store'});
  if(!r.ok)throw Error(p);
  return r.json();
}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function when(s){return s?new Date(s).toLocaleTimeString('es-ES',{hour:'2-digit',minute:'2-digit'}):''}
function isPostUrl(u){return /^https:\/\/(?:www\.)?(?:x|twitter)\.com\/[^/]+\/status\/\d+/i.test(String(u||''))}
function quoteCandidates(x){return (x.quote_candidates||[]).filter(c=>isPostUrl(c?.url)).slice(0,3)}
function quoteSearchUrl(x){
  const saved=String(x.quote_search?.url||'').trim();
  if(/^https:\/\/(?:www\.)?x\.com\/search\?/i.test(saved))return saved;
  const q=String(x.quote_search?.query||x.title||'').trim();
  return 'https://x.com/search?q='+encodeURIComponent(q)+'&src=typed_query&f=live';
}
function quoteIntent(text,postUrl){
  return 'https://twitter.com/intent/tweet?text='+encodeURIComponent(String(text||''))+'&url='+encodeURIComponent(postUrl);
}
function interactionLabel(c){
  if(c.interaction_hint)return String(c.interaction_hint);
  const m=c.metrics_observed||{};
  const nums=['likes','reposts','replies','quotes'].map(k=>Number(m[k])).filter(Number.isFinite);
  if(nums.length)return nums.reduce((a,b)=>a+b,0)+' interacciones observadas';
  return 'Interacción no disponible';
}

async function load(){
  try{
    [prepared,status]=await Promise.all([json('./prepared.json'),json('./status.json')]);
    render();
  }catch(e){
    $('#stamp').textContent='Error al actualizar';
  }
}
function setView(v){
  view=v;
  document.querySelectorAll('.stat').forEach(b=>b.classList.toggle('active',b.dataset.view===v));
  renderList();
}
function render(){
  const items=prepared.items||[];
  $('#ready').textContent=items.length;
  $('#processing').textContent=status.processing_count??0;
  $('#stamp').textContent='Actualizado '+when(status.updated_at||prepared.updated_at||Date.now());
  const ok=status.healthy_source_count??'–',total=status.configured_sources??'–',h=$('#health');
  h.textContent='Fuentes: '+ok+'/'+total+' funcionando';
  h.classList.toggle('bad',Number.isFinite(+ok)&&Number.isFinite(+total)&&+ok<+total);
  renderList();
}
function renderList(){
  const list=$('#list');
  list.innerHTML='';
  if(view==='processing'){renderProcessing(list);return}
  renderReady(list);
}

function renderQuotePanel(host,x,onSelect){
  const panel=document.createElement('section');
  panel.className='quote-panel';
  const candidates=quoteCandidates(x);
  const head=document.createElement('div');
  head.className='quote-head';
  head.innerHTML='<strong>💬 Tuit para citar</strong><span>Conversación relacionada · se prioriza poca interacción</span>';
  panel.appendChild(head);

  if(candidates.length){
    const group=document.createElement('div');
    group.className='quote-candidates';
    candidates.forEach((c,i)=>{
      const label=document.createElement('label');
      label.className='quote-candidate';
      const radio=document.createElement('input');
      radio.type='radio';
      radio.name='quote-'+x.event_id;
      radio.checked=i===0;
      radio.onchange=()=>onSelect(c.url);
      const body=document.createElement('span');
      body.className='quote-body';
      const author=esc(c.author||c.account||'Cuenta de X');
      const excerpt=esc(c.text_excerpt||c.text||'Abrir publicación');
      const meta=[interactionLabel(c),c.published_at?('· '+when(c.published_at)):''].filter(Boolean).join(' ');
      body.innerHTML='<b>'+author+'</b><span class="quote-text">'+excerpt+'</span><small>'+esc(meta)+'</small>'+(c.reason?'<small class="quote-reason">'+esc(c.reason)+'</small>':'');
      const open=document.createElement('a');
      open.href=c.url;
      open.target='_blank';
      open.rel='noopener';
      open.className='quote-open';
      open.textContent='Ver';
      open.onclick=e=>e.stopPropagation();
      label.append(radio,body,open);
      group.appendChild(label);
    });
    panel.appendChild(group);
  }else{
    const empty=document.createElement('p');
    empty.className='quote-empty';
    empty.textContent='No se encontró un comentario suficientemente adecuado para citar automáticamente.';
    panel.appendChild(empty);
  }

  const search=document.createElement('a');
  search.href=quoteSearchUrl(x);
  search.target='_blank';
  search.rel='noopener';
  search.className='quote-search';
  search.textContent='🔎 Buscar otro en X';
  panel.appendChild(search);
  host.appendChild(panel);
  return candidates[0]?.url||'';
}

async function copyImage(url,btn){
  try{
    const r=await fetch(url,{cache:'no-store'}); if(!r.ok)throw Error('fetch');
    const blob=await r.blob();
    if(!navigator.clipboard||!window.ClipboardItem)throw Error('clipboard');
    await navigator.clipboard.write([new ClipboardItem({[blob.type]:blob})]);
    const old=btn.textContent;btn.textContent='✓ Imagen copiada';setTimeout(()=>btn.textContent=old,1600);
  }catch(_){alert('El navegador no permite copiar esta imagen directamente. Usa Descargar imagen.');}
}
function renderImagePanel(host,x){
  const im=x.image||{};const url=String(im.url||'').trim();if(!url)return;
  const box=document.createElement('section');box.className='image-panel';
  const img=document.createElement('img');img.src=url;img.alt=im.alt||'Imagen de la noticia';img.loading='lazy';
  const meta=document.createElement('div');meta.className='image-meta';
  meta.innerHTML='<strong>'+(im.generated?'🎨 Gag visual':'🖼️ Imagen de archivo')+'</strong><span>'+esc(im.generated?'TTiTTulares · imagen original':'Fuente: '+(im.source||'medio'))+'</span>';
  const actions=document.createElement('div');actions.className='image-actions';
  const copy=document.createElement('button');copy.type='button';copy.textContent='Copiar imagen';copy.onclick=()=>copyImage(url,copy);
  const open=document.createElement('a');open.href=url;open.target='_blank';open.rel='noopener';open.textContent='Abrir imagen';
  const dl=document.createElement('a');dl.href=url;dl.download='ttittulares-'+(x.event_id||'imagen')+(url.includes('.png')?'.png':url.includes('.jpg')||url.includes('.jpeg')?'.jpg':'.webp');dl.textContent='Descargar imagen';
  actions.append(copy,open,dl);box.append(img,meta,actions);host.appendChild(box);
}

function renderReady(list){
  $('#viewTitle').textContent='Noticias listas';
  $('#viewHelp').textContent='Solo entran noticias con al menos 4 fuentes. Ordenadas por número actual de fuentes y después por recencia.';
  const items=[...(prepared.items||[])].sort((a,b)=>{
    const ac=status.events?.[a.event_id]?.source_count||a.drafted_source_count||0;
    const bc=status.events?.[b.event_id]?.source_count||b.drafted_source_count||0;
    return bc-ac||String(b.prepared_at||'').localeCompare(String(a.prepared_at||''));
  });
  if(!items.length){
    list.innerHTML='<div class="empty">No hay noticias redactadas pendientes.</div>';
    return;
  }

  for(const x of items){
    const n=$('#card').content.cloneNode(true);
    const card=n.querySelector('.card');
    const cur=status.events?.[x.event_id]?.source_count??x.drafted_source_count??0;
    const draft=x.drafted_source_count??cur;
    n.querySelector('.title').textContent=x.title||'Sin titular';
    n.querySelector('.meta').textContent='Redactada con '+draft+' ('+cur+') · '+when(x.prepared_at);
    n.querySelector('.facts').textContent=x.factual_summary||'';

    const vs=n.querySelector('.variants');
    renderImagePanel(vs,x);
    const quoteLinks=[];
    let selectedQuote='';

    selectedQuote=renderQuotePanel(vs,x,url=>{
      selectedQuote=url;
      for(const q of quoteLinks){
        q.a.href=quoteIntent(q.text,selectedQuote);
        q.a.hidden=!selectedQuote;
      }
    });

    for(const v of x.variants||[]){
      const d=document.createElement('div');
      d.className='variant';
      const title=document.createElement('strong');
      title.textContent=v.label||v.name||'Opción';
      const p=document.createElement('p');
      p.textContent=v.text||'';
      const links=document.createElement('div');
      links.className='variant-links';

      const publish=document.createElement('a');
      publish.target='_blank';
      publish.rel='noopener';
      publish.href=v.url||v.tweet_url||'#';
      publish.textContent='Publicar en X';
      links.appendChild(publish);

      const quote=document.createElement('a');
      quote.target='_blank';
      quote.rel='noopener';
      quote.className='quote-action';
      quote.textContent='Citar elegido';
      quote.hidden=!selectedQuote;
      if(selectedQuote)quote.href=quoteIntent(v.text||'',selectedQuote);
      quoteLinks.push({a:quote,text:v.text||''});
      links.appendChild(quote);

      d.append(title,p,links);
      vs.appendChild(d);
    }

    n.querySelector('.summary').onclick=()=>card.classList.toggle('open');
    n.querySelectorAll('[data-act]').forEach(b=>b.onclick=()=>act(b.dataset.act,x));
    list.appendChild(n);
  }
}

function renderProcessing(list){
  $('#viewTitle').textContent='En elaboración';
  $('#viewHelp').textContent='Noticias que ya alcanzaron 4 fuentes y están esperando o pasando por el pase editorial.';
  const items=status.processing_items||[];
  if(!items.length){
    list.innerHTML='<div class="empty">No hay noticias en elaboración.</div>';
    return;
  }
  for(const x of items)list.appendChild(queueCard(x));
}
function queueCard(x){
  const a=document.createElement('article');
  a.className='queuecard';
  const chips=(x.sources||[]).map(s=>'<span class="chip">'+esc(typeof s==='string'?s:(s.name||s.source||''))+'</span>').join('');
  a.innerHTML='<h3>'+esc(x.title||'Sin titular')+'</h3><p>'+esc((x.source_count||0)+' fuentes · entrada '+when(x.selected_at))+'</p><div class="chips">'+chips+'</div>'+(x.url?'<p><a class="source-link" target="_blank" rel="noopener" href="'+esc(x.url)+'">Abrir noticia base</a></p>':'');
  return a;
}
async function act(action,x){
  if(action==='rewrite'){
    active=x;
    $('#rewriteText').value='';
    $('#rewriteDlg').showModal();
    return;
  }
  await send(action,x,'');
}
async function send(action,x,instructions){
  const r=await fetch('/api/ttittulares-control',{
    method:'POST',
    headers:{'content-type':'application/json'},
    body:JSON.stringify({action,event_id:x.event_id,instructions})
  });
  if(!r.ok){alert('No se pudo guardar la acción');return}
  await load();
}

function duration(s){if(s==null||!Number.isFinite(+s))return '';s=+s;if(s<60)return s+' s';return Math.floor(s/60)+' min '+(s%60)+' s'}
function runKey(){return localStorage.getItem('ttittularesRunKey')||''}
function runVisual(s){
  const el=$('#runState'),btn=$('#runNow');el.className='';btn.disabled=false;
  if(s&&s.status==='DISABLED'){el.textContent='Preparado · falta activar trigger Work';el.className='';btn.disabled=true;return}
  if(!s||s.status==='IDLE'){el.textContent=runKey()?'Listo para ejecutar':'Pedirá clave al primer uso';return}
  if(s.status==='REQUESTED'){el.textContent='Solicitada '+when(s.requested_at)+' · esperando a Work';el.className='running';btn.disabled=true;return}
  if(s.status==='RUNNING'){el.textContent='Ejecutándose desde '+when(s.started_at)+(s.start_delay_seconds!=null?' · arrancó en '+duration(s.start_delay_seconds):'');el.className='running';btn.disabled=true;return}
  if(s.status==='DONE'){el.textContent='Terminada '+when(s.finished_at)+(s.start_delay_seconds!=null?' · arranque '+duration(s.start_delay_seconds):'')+(s.duration_seconds!=null?' · duración '+duration(s.duration_seconds):'');el.className='done';return}
  if(s.status==='ERROR'){el.textContent='Error '+when(s.finished_at)+(s.message?' · '+s.message:'');el.className='error';return}
  el.textContent=s.status||'Estado desconocido';
}
async function loadRunStatus(){
  const key=runKey();
  try{
    const headers=key?{'x-tt-run-key':key}:{};
    const r=await fetch('/api/ttittulares-run-status?t='+Date.now(),{cache:'no-store',headers});
    if(r.status===401){if(key)localStorage.removeItem('ttittularesRunKey');runVisual({status:'IDLE'});scheduleRunPoll(false);return}
    if(!r.ok)throw Error('status');
    const s=await r.json();runVisual(s);scheduleRunPoll(['REQUESTED','RUNNING'].includes(s.status));
  }catch(_){$('#runState').textContent='No se pudo consultar el estado';$('#runState').className='error';scheduleRunPoll(false)}
}
function scheduleRunPoll(fast){
  clearTimeout(runPoll);runPoll=setTimeout(loadRunStatus,fast?5000:60000);
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
    if(r.status===503&&j.error==='work_trigger_not_ready')throw Error('El trigger de Work todavía no está activado')
    if(!r.ok)throw Error(j.detail||j.error||'No se pudo solicitar la ejecución');
    runVisual({status:'REQUESTED',requested_at:j.requested_at});scheduleRunPoll(true);
  }catch(e){$('#runState').textContent=String(e.message||e);$('#runState').className='error';btn.disabled=false}
}

$('#rewriteOk').onclick=async e=>{
  e.preventDefault();
  const t=$('#rewriteText').value.trim();
  if(!t)return;
  $('#rewriteDlg').close();
  await send('rewrite',active,t);
};
document.querySelectorAll('.stat').forEach(b=>b.onclick=()=>setView(b.dataset.view));
$('#refresh').onclick=()=>{load();loadRunStatus()};
$('#runNow').onclick=requestRun;
load();
loadRunStatus();
setInterval(load,60000);
