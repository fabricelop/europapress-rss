import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const source = resolve(import.meta.dirname, "../web-source");
const html = readFileSync(resolve(source,"index.html"),"utf8");
const manifest = JSON.parse(readFileSync(resolve(source,"manifest.webmanifest"),"utf8"));

test("V2 advertises real local icons for browser and iOS home screen",()=>{
  assert.match(html, /rel="icon" href="\.\/icon\.svg"/);
  assert.match(html, /rel="apple-touch-icon" href="\.\/apple-touch-icon\.png" sizes="180x180"/);
  assert.match(html, /rel="manifest" href="\.\/manifest\.webmanifest"/);
  assert.equal(manifest.icons.length,2);
  for (const icon of manifest.icons) {
    assert.ok(icon.src.startsWith("./"));
    assert.equal(icon.type,"image/png");
    assert.equal(icon.purpose,"any maskable");
  }
});

test("all branded PNG assets contain the promised dimensions",()=>{
  for (const [filename,expected] of [["apple-touch-icon.png",180],["icon-192.png",192],["icon-512.png",512]]) {
    const data=readFileSync(resolve(source,filename));
    assert.equal(data.subarray(0,8).toString("hex"),"89504e470d0a1a0a",filename);
    assert.equal(data.readUInt32BE(16),expected,filename+" width");
    assert.equal(data.readUInt32BE(20),expected,filename+" height");
  }
  const svg=readFileSync(resolve(source,"icon.svg"),"utf8");
  assert.match(svg,/<svg\b/);
  assert.match(svg,/>TT<\/text>/);
  const ico=readFileSync(resolve(source,"favicon.ico"));
  assert.equal(ico.readUInt16LE(2),1);
});
