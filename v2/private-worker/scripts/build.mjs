import { cp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { resolve } from "node:path";

const output = resolve(import.meta.dirname, "../dist");
const source = resolve(import.meta.dirname, "../web-source");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const filename of ["index.html", "styles.css", "app.js", "manifest.webmanifest"]) {
  await cp(resolve(source, filename), resolve(output, filename));
}
// Private UI sources live here; they no longer depend on docs/v2 on main.
// The private origin must never fetch its JSON directly from public GitHub.
// Nor should the old Pages service worker cache authenticated content.
let app = await readFile(resolve(output, "app.js"), "utf8");
const old = 'const BASE="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/state/";';
if (!app.includes(old)) throw Error("V2 upstream data URL has changed: stop before shipping");
app = app.replace(old, 'const BASE="/api/state/";');
const oldPublicUrl = 'const WEB_URL="https://fabricelop.github.io/europapress-rss/v2/";';
if (!app.includes(oldPublicUrl)) throw Error("Old public tweet URL not found; stop build");
app = app.replace(oldPublicUrl, 'const WEB_URL="https://ttactualidad.rainyraven22.chatgpt.site/";');
const radarFunction = [
'function updateRadar(capturedAt){',
' const root=document.getElementById("results");',
' if(!root)return;',
' let banner=document.getElementById("radar-time");',
' if(!banner){banner=document.createElement("div");banner.id="radar-time";banner.className="radar-time";root.before(banner)}',
' const date=new Date(capturedAt);',
' if(!capturedAt||!Number.isFinite(date.getTime())){banner.textContent="Radar · hora no disponible";banner.removeAttribute("title");return}',
' const time=new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",hour:"2-digit",minute:"2-digit"}).format(date);',
' banner.textContent="Radar · "+time;',
' banner.title="Última captura: "+new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",dateStyle:"full",timeStyle:"short"}).format(date);',
'}',
].join("\n");
if (!app.includes('function markStamp(item)')) throw Error("Cannot add Radar function");
app = app.replace('function markStamp(item)', radarFunction + "\nfunction markStamp(item)");
if (!app.includes('state.captured=data.captured_at;')) throw Error("Cannot attach radar data");
app = app.replace('state.captured=data.captured_at;', 'state.captured=data.captured_at;\n  updateRadar(state.captured);');
const pilotBefore = '  card.append(body);';
if (!app.includes(pilotBefore)) throw Error("Pilot card anchor missing");
app = app.replace(pilotBefore, [
'  card.append(body);',
'  if(item.trend_id==="trv2-e94b2984c087ac403753b8c1"){',
'   const figure=el("figure","pilot-figure");',
'   const img=document.createElement("img");',
'   img.src="/pilot/jordi-wild.webp";img.alt="Viñeta piloto: tres entrevistas y una silla vacía";',
'   img.loading="lazy";figure.append(img);',
'   const cap=el("figcaption","pilot-caption","Imagen piloto · no publicada");figure.append(cap);',
'   card.append(figure);',
'  }',
].join("\n"));


await writeFile(resolve(output, "app.js"), app, "utf8");
let css=await readFile(resolve(output, "styles.css"), "utf8");
css += "\n.radar-time{padding:11px clamp(15px,4vw,36px);background:#121720;color:#b4c3d4;border-bottom:1px solid #272b33;font-size:13px;font-variant-numeric:tabular-nums}.pilot-figure{margin:0;padding:0 clamp(15px,4vw,36px) 22px calc(clamp(15px,4vw,36px) + 48px)}.pilot-figure img{display:block;max-width:360px;width:100%;height:auto;border-radius:10px}.pilot-caption{font-size:11px;color:#929eab;margin-top:6px}@media(max-width:450px){.pilot-figure{padding:0 14px 18px 52px}}\n";
await writeFile(resolve(output,"styles.css"),css,"utf8");
let html = await readFile(resolve(output, "index.html"), "utf8");
html = html.replace(/<script>if\("serviceWorker" in navigator\)[\s\S]*?<\/script>/, "");
html = html.replace(/href="\.\/styles\.css\?v=\d+"/, 'href="./styles.css"');
html = html.replace(/src="\.\/app\.js\?v=\d+"/, 'src="./app.js"');
await writeFile(resolve(output, "index.html"), html, "utf8");
console.log("TT_V2_PRIVATE_BUILD_READY=YES");
