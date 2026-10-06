const $=s=>document.querySelector(s);
let prepared={items:[]},status={},active=null,view='ready',runPoll=null;

async function json(p){
  const r=await fetch(p+'?t='+Date.now(),{cache:'no-store'});
  if(!r.ok)throw Error(p);
  return r.json();
}
function esc(s){return String(s??'').replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]))}
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
  const source1=$('#source1'),source2=$('#source2'),source3=$('#source3');
  if(source1)source1.textContent=status.one_source_count??0;
  if(source2)source2.textContent=status.two_source_count??0;
  if(source3)source3.textContent=status.three_source_count??(status.three_source_items||[]).length??0;
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
  const strong=document.createElement('strong');strong.textContent=aiUrl?'Imagen IA':'Imagen de archivo';
  const badge=document.createElement('span');badge.textContent=aiUrl?'Lista para publicar':(fallbackUrl?'Alternativa disponible':'Sin imagen');
  head.append(strong,badge);box.appendChild(head);

  const imageUrl=aiUrl||fallbackUrl;
  if(imageUrl){const img=document.createElement('img');img.src=imageUrl;img.alt=x.title||'Imagen';img.loading='lazy';box.appendChild(img)}
  const actions=document.createElement('div');actions.className='image-actions';
  if(imageUrl){
    const copy=document.createElement('button');copy.type='button';copy.textContent='Copiar imagen';copy.onclick=()=>copyImage(imageUrl,copy);actions.appendChild(copy);
    const open=document.createElement('a');open.href=imageUrl;open.target='_blank';open.rel='noopener';open.textContent='Abrir imagen';actions.appendChild(open);
  }
  box.appendChild(actions);host.appendChild(box);
}

function renderReady(list){
  $('#viewTitle').textContent='Noticias listas';$('#viewHelp').textContent='Toca una noticia para abrirla.';
  const items=prepared.items||[];if(!items.length){list.innerHTML='<div class="empty">No hay noticias listas.</div>';return}
  items.forEach(x=>{
    const node=$('#card').content.cloneNode(true),card=node.querySelector('.card');
    node.querySelector('.title').textContent=x.title||'Sin título';node.querySelector('.meta').textContent=(x.source_count||0)+' fuentes';
    node.querySelector('.summary').onclick=()=>card.classList.toggle('open');
    node.querySelector('.facts').textContent=x.factual_summary||'';
    const variants=node.querySelector('.variants');let selectedQuote='';
    (x.variants||[]).forEach((v,i)=>{
      const d=document.createElement('div');d.className='variant';const p=document.createElement('p');p.textContent=v.text||v.tweet||'';d.appendChild(p);
      const links=document.createElement('div');links.className='variant-links';
      const a=document.createElement('a');a.href=v.url||x.url||'#';a.target='_blank';a.rel='noopener';a.textContent='Abrir fuente';links.appendChild(a);
      const q=document.createElement('a');q.className='quote-action';q.target='_blank';q.rel='noopener';q.textContent='Citar en X';q.hidden=!selectedQuote;q.href=quoteIntent(v.text||v.tweet||'',selectedQuote);links.appendChild(q);d.appendChild(links);variants.appendChild(d);
    });
    selectedQuote=renderQuotePanel(variants,x,url=>{selectedQuote=url;variants.querySelectorAll('.quote-action').forEach((a,i)=>{const v=(x.variants||[])[i]||{};a.hidden=!url;a.href=quoteIntent(v.text||v.tweet||'',url)})});
    if(selectedQuote)variants.querySelectorAll('.quote-action').forEach((a,i)=>{const v=(x.variants||[])[i]||{};a.hidden=false;a.href=quoteIntent(v.text||v.tweet||'',selectedQuote)});
    renderImagePanel(variants,x);
    node.querySelectorAll('[data-act]').forEach(b=>b.onclick=()=>action(x,b.dataset.act));list.appendChild(node);
  });
}
function renderProcessing(list){
  $('#viewTitle').textContent='En elaboración';$('#viewHelp').textContent='Noticias que ya han salido de Creciendo y están siendo elaboradas.';
  const items=status.processing_items||[];if(!items.length){list.innerHTML='<div class="empty">No hay noticias en elaboración.</div>';return}
  items.forEach(x=>{const a=document.createElement('article');a.className='queuecard';a.innerHTML='<h3>'+esc(x.title||'Sin título')+'</h3><p>'+esc(when(x.selected_at))+' · '+esc(x.source_count||0)+' fuentes</p><div class="chips">'+(x.sources||[]).map(s=>'<span class="chip">'+esc(s)+'</span>').join('')+'</div>';list.appendChild(a)})
}
async function action(x,act){
  if(act==='rewrite'){active=x;$('#rewriteText').value='';$('#rewriteDlg').showModal();return}
  try{await fetch('/api/ttittulares-control',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:act,event_id:x.event_id})});await load()}catch(e){alert('No se pudo guardar el cambio')}
}

async function runNow(){
  const b=$('#runNow'),s=$('#runState');b.disabled=true;s.textContent='Lanzando…';s.className='running';
  try{
    const r=await fetch('/api/ttittulares-run',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}),j=await r.json();
    if(!r.ok||!j.ok)throw Error(j.error||'run');s.textContent='En ejecución';pollRun();
  }catch(e){s.textContent='Error al lanzar';s.className='error';b.disabled=false}
}
async function pollRun(){
  clearTimeout(runPoll);
  try{
    const j=await json('/api/ttittulares-run');
    const b=$('#runNow'),s=$('#runState');
    if(j.running){b.disabled=true;s.textContent='En ejecución';s.className='running';runPoll=setTimeout(pollRun,3000);return}
    b.disabled=false;
    if(j.last_status==='success'){s.textContent='Última ejecución correcta';s.className='done';await load()}
    else if(j.last_status==='failure'){s.textContent='Última ejecución fallida';s.className='error'}
    else{s.textContent='Disponible';s.className=''}
  }catch(e){$('#runNow').disabled=false;$('#runState').textContent='Disponible';$('#runState').className=''}
}

document.querySelectorAll('.stat').forEach(b=>b.onclick=()=>setView(b.dataset.view));
$('#refresh').onclick=load;$('#runNow').onclick=runNow;
$('#rewriteOk').onclick=async e=>{e.preventDefault();if(!active)return;const instructions=$('#rewriteText').value.trim();$('#rewriteDlg').close();try{await fetch('/api/ttittulares-control',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:'rewrite',event_id:active.event_id,instructions})});await load()}catch(e){alert('No se pudo enviar a elaborar')}};
load();pollRun();