import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const html=readFileSync(new URL('./umami-head.html',import.meta.url),'utf8');

test('Umami tracking script matches the exact original site account',()=>{
  assert.match(html,/src="https:\/\/cloud\.umami\.is\/script\.js"/);
  assert.match(html,/data-website-id="646e82d3-bfaf-4b2e-b274-fc6b0e295b0d"/);
  assert.equal((html.match(/<script\b/g)||[]).length,1);
  assert.match(html,/\sdefer\s/);
});
test('Umami site snippet does not leak credentials or capture form contents',()=>{
  assert.doesNotMatch(html,/api[_-]?key|secret|token|document\.cookie|localStorage|email|querySelector/gi);
});
