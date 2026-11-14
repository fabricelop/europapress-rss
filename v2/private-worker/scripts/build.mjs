import { cp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const output = resolve(import.meta.dirname, "../dist");
const source = resolve(root, "docs/v2");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const filename of ["index.html", "styles.css", "app.js", "manifest.webmanifest"]) {
  await cp(resolve(source, filename), resolve(output, filename));
}
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
if (!app.includes('const MARKS_KEY=')) throw Error("Cannot add Radar function");
app = app.replace('const MARKS_KEY=', radarFunction + "\nconst MARKS_KEY=");
if (!app.includes('state.captured=data.captured_at;')) throw Error("Cannot attach radar data");
app = app.replace('state.captured=data.captured_at;', 'state.captured=data.captured_at;\n  updateRadar(state.captured);');

await writeFile(resolve(output, "app.js"), app, "utf8");
let css=await readFile(resolve(output, "styles.css"), "utf8");
css += "\n.radar-time{padding:11px clamp(15px,4vw,36px);background:#121720;color:#b4c3d4;border-bottom:1px solid #272b33;font-size:13px;font-variant-numeric:tabular-nums}\n";
await writeFile(resolve(output,"styles.css"),css,"utf8");
let html = await readFile(resolve(output, "index.html"), "utf8");
html = html.replace(/<script>if\("serviceWorker" in navigator\)[\s\S]*?<\/script>/, "");
html = html.replace(/href="\.\/styles\.css\?v=\d+"/, 'href="./styles.css"');
html = html.replace(/src="\.\/app\.js\?v=\d+"/, 'src="./app.js"');
await writeFile(resolve(output, "index.html"), html, "utf8");
console.log("TT_V2_PRIVATE_BUILD_READY=YES");
