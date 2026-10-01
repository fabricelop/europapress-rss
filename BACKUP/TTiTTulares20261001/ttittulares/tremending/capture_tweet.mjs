#!/usr/bin/env node
/* Capture a user-selected public X embed without generating an image. */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"../..");
const statePath=path.join(root,"ttittulares","tremending","items.json");
const imageDir=path.join(root,"ttittulares","tremending-images");
const rawBase="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/";
const esc=value=>String(value||"").replace(/[&<>\"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const now=()=>new Date().toISOString();
const load=async file=>JSON.parse(await fs.readFile(file,"utf8"));
const save=async(file,value)=>fs.writeFile(file,JSON.stringify(value,null,2)+"\n","utf8");

function fallbackHtml(tweet,text){return `<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:#fff;font-family:system-ui,-apple-system,Segoe UI,sans-serif;color:#0f1419}.card{margin:22px;border:1px solid #cfd9de;border-radius:16px;padding:22px;max-width:580px}.warning{font-size:11px;font-weight:800;letter-spacing:.05em;color:#b4234d;margin-bottom:16px}.author{font-weight:800}.text{font-size:19px;line-height:1.38;margin:18px 0;white-space:pre-wrap}.url{font-size:12px;color:#536471;word-break:break-all}</style><main class="card"><div class="warning">REPRODUCCIÓN GRÁFICA DEL TEXTO · X NO PERMITIÓ LA CAPTURA</div><div class="author">${esc(tweet.author||"Publicación de X")}</div><div class="text">${esc(text||"El texto no pudo recuperarse; consulta la publicación original.")}</div><div class="url">${esc(tweet.url)}</div></main>`}
async function oembedText(url){
 const r=await fetch("https://publish.twitter.com/oembed?url="+encodeURIComponent(url)+"&omit_script=true",{headers:{"user-agent":"TTiTTulares-Tremending-Capture/1.0"}});
 if(!r.ok)throw new Error("oEmbed HTTP "+r.status);
 const data=await r.json();return String(data.html||"").replace(/<br\s*\/?\s*>/gi,"\n").replace(/<[^>]+>/g," ").replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/\s+\n/g,"\n").replace(/[ \t]{2,}/g," ").trim()
}
async function screenshotOfficial(page,tweet,out){
 await page.setViewportSize({width:680,height:900});
 await page.goto(tweet.embed_url||("https://platform.twitter.com/embed/Tweet.html?id="+tweet.id+"&dnt=true"),{waitUntil:"domcontentloaded",timeout:30000});
 await page.waitForTimeout(2500);
 const body=page.locator("body");const box=await body.boundingBox();
 if(!box||box.width<200||box.height<100)throw new Error("embed vacío");
 await body.screenshot({path:out});
}
async function propagate(state){
 const processingPath=path.join(root,"telegram","editorial-processing.json"),preparedPath=path.join(root,"ttittulares","prepared.json");
 for(const file of [processingPath,preparedPath]){
  const doc=await load(file);let changed=false;
  for(const entry of state.items||[]){
   if(entry.image?.status!=="ready"||!entry.image?.url)continue;
   for(const row of doc.items||[]){if(row.tremending_id!==entry.id)continue;row.image={...entry.image};row.image_status="ready";row.image_pending=false;changed=true}
  }
  if(changed){doc.updated_at=now();await save(file,doc)}
 }
}
async function main(){
 const state=await load(statePath);const pending=(state.items||[]).filter(x=>x?.image?.status==="pending_capture"&&x.selected_tweet_id);
 if(!pending.length){console.log("TREMENDING_CAPTURE_NOTHING_TO_DO");return}
 const {chromium}=await import("playwright");await fs.mkdir(imageDir,{recursive:true});const browser=await chromium.launch({headless:true});
 try{for(const item of pending){const tweet=(item.tweets||[]).find(x=>String(x.id)===String(item.selected_tweet_id));if(!tweet)continue;const file=`${tweet.id}.png`,out=path.join(imageDir,file),page=await browser.newPage();let kind="official_embed",fallbackReason="";
   try{await screenshotOfficial(page,tweet,out)}catch(error){kind="text_reproduction";fallbackReason=String(error.message||error);let text="";try{text=await oembedText(tweet.url)}catch(embedError){fallbackReason+="; "+String(embedError.message||embedError)}await page.setContent(fallbackHtml(tweet,text),{waitUntil:"load"});await page.screenshot({path:out,fullPage:true})}
   await page.close();item.image={status:"ready",kind,tweet_id:String(tweet.id),tweet_url:tweet.url,url:rawBase+"ttittulares/tremending-images/"+file,static_path:"ttittulares/tremending-images/"+file,captured_at:now(),...(fallbackReason?{fallback_reason:fallbackReason}:{})};item.updated_at=now();console.log(`TREMENDING_CAPTURED ${item.id} ${kind}`)
  }}finally{await browser.close()}
 state.updated_at=now();await save(statePath,state);await propagate(state)
}
main().catch(error=>{console.error(error);process.exitCode=1});
