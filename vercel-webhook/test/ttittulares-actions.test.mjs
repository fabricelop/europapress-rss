import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const html=fs.readFileSync(new URL('../ttittulares/index.html',import.meta.url),'utf8'),script=html.match(/<script>([\s\S]*?)<\/script>/)[1];new vm.Script(script);
class Element{constructor(){this.children=[];this.dataset={};this.style={};this.hidden=false;this.classList={add(){},toggle(){},contains(){return false}}}querySelector(k){return (this.nodes||={})[k]||=new Element()}appendChild(e){this.children.push(e)}getAttribute(k){return this[k]}replaceWith(){}}
for(const images of ['both','ai','archive','none'])test('acciones y copias: '+images,async()=>{
 const item={event_id:'test',title:'Prueba',tweet:{text:'Hecho factual\n\n🌶️ Remate.'},ai_image_status:'failed'};
 if(['both','ai'].includes(images))item.ai_image={url:'https://image.test/ai.png',generated:true,provider:'chat-imagegen',origin:'executing_chat',context_guard:{version:3,scope:'current_item_only'}};
 if(['both','archive'].includes(images))item.fallback_image={url:'https://image.test/archive.png'};
 const list=new Element(),calls=[],copied=[],c={document:{createElement(){return new Element()}},$:()=>new Element(),model:{prepared:[item],status:{}},pendingClosed:new Set(),openCards:new Set(),API:'/api/ttittulares-control',fmt:()=>'',quoteSearchUrl:()=>'',newsSearchKeywords:()=>'',tweetFor:x=>x.tweet,mountRemateRating(){},navigator:{clipboard:{writeText:async text=>copied.push(text)}},copyImageToClipboard:url=>copied.push(url),toast(){},confirm:()=>true,api:async(...args)=>calls.push(args),load:async()=>{},render(){},persistUiState(){}};
 vm.createContext(c);vm.runInContext(script.slice(script.indexOf('function isChatImageGen('),script.indexOf('function renderProblematic(')),c);c.renderReady(list);const card=list.children[0];assert.ok(card);assert.equal(Boolean(card.querySelector('.copyAi').onclick),Boolean(item.ai_image));assert.equal(Boolean(card.querySelector('.copyArchive').onclick),Boolean(item.fallback_image));
 await card.querySelector('.copyTweet').onclick();assert.equal(copied[0],item.tweet.text);
 for(const [selector,url] of [['.copyAi',item.ai_image?.url],['.copyArchive',item.fallback_image?.url]])if(url){card.querySelector(selector).onclick();assert.equal(copied.at(-1),url)}
 for(const [selector,action] of [['.rework','rework'],['.published','published'],['.dismiss','dismiss']]){await card.querySelector(selector).onclick();assert.equal(calls.at(-1)[0],action)}
});
test('alta manual solo noticia e instrucciones',()=>{assert.ok(!html.includes('submitUrl'));assert.match(html,/placeholder="Noticia" required/);assert.match(script,/api\("submit",\{title,instruction\}\)/)});
