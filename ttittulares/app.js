const $=s=>document.querySelector(s);
let prepared={items:[]},status={},active=null,view='ready';

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
$('#rewriteOk').onclick=async e=>{
  e.preventDefault();
  const t=$('#rewriteText').value.trim();
  if(!t)return;
  $('#rewriteDlg').close();
  await send('rewrite',active,t);
};
document.querySelectorAll('.stat').forEach(b=>b.onclick=()=>setView(b.dataset.view));
$('#refresh').onclick=load;
load();
setInterval(load,60000);
