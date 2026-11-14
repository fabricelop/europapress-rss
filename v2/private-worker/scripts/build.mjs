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
await writeFile(resolve(output, "app.js"), app, "utf8");
let html = await readFile(resolve(output, "index.html"), "utf8");
html = html.replace(/<script>if\("serviceWorker" in navigator\)[\s\S]*?<\/script>/, "");
html = html.replace(/href="\.\/styles\.css\?v=\d+"/, 'href="./styles.css"');
html = html.replace(/src="\.\/app\.js\?v=\d+"/, 'src="./app.js"');
await writeFile(resolve(output, "index.html"), html, "utf8");
console.log("TT_V2_PRIVATE_BUILD_READY=YES");
