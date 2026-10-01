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

async function imageBlobToPng(blob){
  if(blob.type==='image/png')return blob;
  const bitmap=await createImageBitmap(blob);
  const canvas=document.createElement('canvas');canvas.width=bitmap.width;canvas.height=bitmap.height;
  canvas.getContext('2d').drawImage(bitmap,0,0);if(typeof bitmap.close==='function')bitmap.close();
  return await new Promise((resolve,reject)=>canvas.toBlob(x=>x?resolve(x):reject(Error('png')),'image/png'));
}
async function copyImage(url,btn){
  try{
    const r=await fetch(url,{cache:'no-store'});if(!r.ok)throw Error('fetch');
    let blob=await r.blob();blob=await imageBlobToPng(blob);
    if(!navigator.clipboard||!window.ClipboardItem)throw Error('clipboard');
    await navigator.clipboard.write([new ClipboardItem({'image/png':blob})]);
    const old=btn.textContent;btn.textContent='✓ Imagen copiada';setTimeout(()=>btn.textContent=old,1600);
  }catch(_){alert('El navegador no permite copiar esta imagen directamente. Usa Descargar imagen.');}
}
function isChatImageGen(image){
  const guard=image?.context_guard||{};
  return image?.generated===true&&image?.provider==='chat-imagegen'&&image?.origin==='executing_chat'&&Number(guard.version)===3&&guard.scope==='current_item_only';
}
function renderImagePanel(host,x){
  const rawAi=x.ai_image||{},ai=isChatImageGen(rawAi)?rawAi:{},fallback=x.fallback_image||{};
  const aiUrl=String(ai.url||'').trim(),fallbackUrl=String(fallback.url||'').trim();
  const box=document.createElement('section');box.className='image-panel';

  const head=document.createElement('div');head.className='image-meta';
  let choice=String(x.image_choice|| (aiUrl?'ai':fallbackUrl?'fallback':'none'));
  if(choice==='ai'&&!aiUrl)choice=fallbackUrl?'fallback':'none';
  const selected=choice==='ai'?ai:choice==='fallback'?fallback:{};
  const selectedUrl=String(selected.url||'').trim();
  head.innerHTML='<strong>🖼️ Imágenes</strong><span>'+(choice==='ai'?'Usando gag IA':choice==='fallback'?'Usando archivo/fallback':'Puedes publicar también sin imagen')+'</span>';
  box.appendChild(head);

  const grid=document.createElement('div');
  grid.style.cssText='display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin-top:8px';
  function addPreview(image,label,isSelected){
    const url=String(image?.url||'').trim();if(!url)return false;
    const card=document.createElement('div');card.style.cssText='border:1px solid #334155;border-radius:10px;padding:8px;min-width:0';
    const lab=document.createElement('div');lab.style.cssText='display:flex;justify-content:space-between;font-size:12px;font-weight:800;margin-bottom:6px';
    lab.textContent=label;
    if(isSelected){const b=document.createElement('span');b.textContent='EN USO';b.style.cssText='color:#f5c451';lab.appendChild(b)}
    const img=document.createElement('img');
    img.src='/api/ttittulares-control?view=image-proxy&url='+encodeURIComponent(url);
    img.alt=image.alt||label;img.loading='lazy';img.style.cssText='display:block;width:100%;height:150px;object-fit:contain;border-radius:8px;background:#0b1018';
    const open=document.createElement('a');open.href=url;open.target='_blank';open.rel='noopener';open.appendChild(img);
    const src=document.createElement('small');src.textContent=image.source||label;src.style.cssText='display:block;margin-top:5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#94a3b8';
    card.append(lab,open,src);grid.appendChild(card);return true;
  }
  addPreview(ai,'Gag IA',choice==='ai');
  addPreview(fallback,'Archivo / fallback',choice==='fallback');
  if(!grid.children.length){
    const state=document.createElement('div');state.style.cssText='grid-column:1/-1;padding:10px;border:1px solid #334155;border-radius:10px;color:#94a3b8';
    state.textContent=x.ai_image_regenerate_requested?'Rehacer solicitado · se intentará en la próxima pasada.':'Las imágenes todavía no están disponibles; la noticia sigue lista para publicar.';
    grid.appendChild(state);
  }
  box.appendChild(grid);

  const decisions=document.createElement('div');decisions.className='image-actions';decisions.style.marginTop='8px';
  const redo=document.createElement('button');redo.type='button';redo.textContent=x.ai_image_regenerate_requested?'Rehacer solicitado ✓':'🔁 Rehacer';redo.disabled=Boolean(x.ai_image_regenerate_requested);
  redo.onclick=()=>send('regenerate-image',x,'');
  const useFallback=document.createElement('button');useFallback.type='button';useFallback.textContent='🖼️ Usar archivo/fallback';useFallback.disabled=!fallbackUrl||choice==='fallback';
  useFallback.onclick=()=>send('use-fallback-image',x,'');
  decisions.append(redo,useFallback);box.appendChild(decisions);

  if(selectedUrl){
    const actions=document.createElement('div');actions.className='image-actions';
    const copy=document.createElement('button');copy.type='button';copy.textContent='Copiar imagen';copy.onclick=()=>copyImage('/api/ttittulares-control?view=image-proxy&url='+encodeURIComponent(selectedUrl),copy);
    const open=document.createElement('a');open.href=selectedUrl;open.target='_blank';open.rel='noopener';open.textContent='Abrir imagen';
    const dl=document.createElement('a');dl.href=selectedUrl;dl.download='ttittulares-'+(x.event_id||'imagen')+'.jpg';dl.textContent='Descargar imagen';
    actions.append(copy,open,dl);box.appendChild(actions);
  }
  host.appendChild(box);
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

    const legacy=Array.isArray(x.variants)?x.variants:[];
    const tweet=x.tweet?.text?x.tweet:(legacy.find(v=>String(v?.label||'').toUpperCase()==='A')||legacy.find(v=>String(v?.remate||'').trim()));
    if(tweet){
      const d=document.createElement('div');
      d.className='variant';
      const title=document.createElement('strong');
      title.textContent='Tuit';
      const p=document.createElement('p');
      p.textContent=tweet.text||'';
      const links=document.createElement('div');
      links.className='variant-links';

      const publish=document.createElement('a');
      publish.target='_blank';
      publish.rel='noopener';
      publish.href=tweet.url||tweet.tweet_url||'#';
      publish.textContent='Publicar en X';
      links.appendChild(publish);

      const quote=document.createElement('a');
      quote.target='_blank';
      quote.rel='noopener';
      quote.className='quote-action';
      quote.textContent='Citar elegido';
      quote.hidden=!selectedQuote;
      if(selectedQuote)quote.href=quoteIntent(tweet.text||'',selectedQuote);
      quoteLinks.push({a:quote,text:tweet.text||''});
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
