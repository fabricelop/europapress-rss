import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {resolve} from "node:path";
import {pathToFileURL} from "node:url";
const {chromium}=createRequire(import.meta.url)("playwright");

const browser=await chromium.launch({headless:true,
 executablePath:process.env.TT_V2_CHROMIUM_PATH||undefined,
 args:["--no-sandbox"]});
try{
 for(const width of [320,360,390,430,768,1280]){
  const page=await browser.newPage({viewport:{width,height:780}});
  await page.goto(pathToFileURL(resolve(import.meta.dirname,"../dist/index.html")).href);
  await page.evaluate(()=>{
   const trend=document.getElementById("top30-without-r");
   const news=document.getElementById("news-after-red");
   trend.textContent="18/30";trend.hidden=false;
   news.textContent="12";news.hidden=false;
   document.getElementById("results").style.minHeight="2500px";
  });
  await page.evaluate(()=>scrollTo(0,800));
  const dims=await page.evaluate(()=>{
   const bounds=id=>{const r=document.getElementById(id).getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}};
   return {viewport:innerWidth,document:document.documentElement.scrollWidth,
    scrollY,header:bounds("top-bar"),nav:document.querySelector(".section-nav").getBoundingClientRect().toJSON(),
    trends:bounds("top30-without-r"),news:bounds("news-after-red"),
    tabEnd:bounds("nav-news").right};
  });
  assert.ok(dims.scrollY>100,`scroll did not happen at ${width}px`);
  assert.ok(dims.header.top>=-1&&dims.header.bottom<=dims.nav.top+1,`header not sticky at ${width}px`);
  assert.ok(dims.nav.top>=dims.header.bottom-1,`nav overlaps the top bar at ${width}px`);
  assert.ok(dims.trends.left>=dims.tabEnd,`trends badge overlaps tabs at ${width}px`);
  assert.ok(dims.news.left>=dims.trends.right,`news badge order wrong at ${width}px`);
  assert.ok(dims.news.right<=width,`news badge clipped at ${width}px`);
  assert.ok(dims.document<=width,`horizontal overflow at ${width}px`);
  console.log(`V2_STICKY_TWO_COUNTERS_OK=${width}`);
  await page.close();
 }
}finally{await browser.close();}
