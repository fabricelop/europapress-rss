import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
for(const path of ['pilot/ttactualidad-live/index.html','docs/ttactualidad/index.html']){
 const html=readFileSync(path,'utf8');
 const slice=(from,to)=>{const a=html.indexOf(from),b=html.indexOf(to,a);assert(a>=0&&b>a,path+' extract '+from);return html.slice(a,b)};
 const runtime=vm.createContext({Date,Number,String,Intl,Array,encodeURIComponent,console,Set,Map});
 const funcs=[
  slice('function newestNewsFirst(rows){','\nfunction tabs(){'),
  slice('function xIntentLink(x,body){','\nfunction rowCard(x,i){'),
  slice('function imageWorkflowPrompt(x,associationOnly=false){','\nconst fields=')
 ];
 vm.runInContext(funcs.join('\n'),runtime,{filename:path});
 const rows=[
  {event_id:'b',prepared_at:'2026-11-02T09:00:00Z',revision:1},
  {event_id:'a',prepared_at:'2026-11-02T10:00:00Z',revision:1},
  {event_id:'c',prepared_at:'2026-11-02T08:00:00Z',revision:1}
 ];
 const sorted=vm.runInContext('newestNewsFirst',runtime)(rows);
 assert.deepEqual(sorted.map(x=>x.event_id),['a','b','c'],path+' newest first');
 assert.deepEqual(rows.map(x=>x.event_id),['b','a','c'],path+' does not mutate source');
 if(path.startsWith('pilot')){
  assert.match(html,/return newestNewsFirst\(\(data\.prepared\?\.items\|\|\[\]\)/);
 }else assert.match(html,/if\(state\.tab==='listas'\)return newestNewsFirst\(prepared\.map/);
 const xIntent=vm.runInContext('xIntentLink',runtime);
 for(const [kind,tail] of [['tti','noticias'],['tr','tendencias']]){
  const s='Titular y hechos confirmados\n\n#Etiqueta\n🌶️ Remate';
  const dest=new URL(xIntent({_kind:kind},s));
  assert.equal(dest.hostname,'twitter.com');
  const actual=dest.searchParams.get('text');
  assert.equal(actual,s+'\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/'+tail);
  const long='a'.repeat(260)+'\n\n#Etiqueta\n🌶️ Remate';
  const shortened=new URL(xIntent({_kind:kind},long)).searchParams.get('text');
  assert(shortened.endsWith('#Etiqueta\n🌶️ Remate\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/'+tail));
  const body=shortened.split('\n\nhttps://')[0];
  assert(body.length<long.length,path+' shortens only when needed');
  assert(body.length<=255,path+' reserve the 23-unit t.co link');
 }
 assert.equal((html.match(/xIntentLink\(x,/g)||[]).length,4,path+' all three buttons plus helper');
 assert(!html.includes("'https://twitter.com/intent/tweet?text='+encodeURIComponent(d.editorial"),path+' no old links');
 assert(html.includes("Copiar GAG + asociar IA"));
 assert(html.includes("Asociar JPEG/PNG"));
 const prompt=vm.runInContext('imageWorkflowPrompt',vm.createContext({
  itemData:x=>({title:x.title}),
  String,Number,JSON,Array
 }))({
  _kind:'tti',_status:'LISTA',event_id:'news123456',
  revision:1,prepared_at:'2026-11-02T08:06:00Z',
  title:'Noticia',tweet:{text:'Hechos verificables'}
 },true);
 assert(prompt.includes('JPEG/JPG, PNG o WebP REAL'));
 assert(prompt.includes('pegada o adjunta a ESTE mensaje')||prompt.includes('pegado o adjunto'));
 assert(prompt.includes('NO generes'));
 assert(prompt.includes('SHA-256'));
}
const swift=readFileSync('ios/ttactualidad/TTActualidad/EditorialStore.swift','utf8');
assert(swift.includes('left == right ? $0.id > $1.id : left > right'));
console.log('NEWS_X_SORT_JPEG_WORKFLOW_OK');
