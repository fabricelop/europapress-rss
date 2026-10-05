import test from 'node:test';
import assert from 'node:assert/strict';
import {estimateTranslation,combineMotionEstimates,projectPointSeries,detectNowcastEvent,wetNear} from '../lib/radar-nowcast-core.js';
function mask(w,h,x0,y0,ww=7,hh=7){const a=new Uint8Array(w*h);for(let y=y0;y<y0+hh;y++)for(let x=x0;x<x0+ww;x++)if(x>=0&&x<w&&y>=0&&y<h)a[y*w+x]=1;return a}
test('translation recovers motion',()=>{const w=64,h=64,m=estimateTranslation(mask(w,h,16,24,12,9),mask(w,h,20,22,12,9),w,h,{maxShift:8});assert.equal(m.dx,4);assert.equal(m.dy,-2);assert.ok(m.confidence>.55)});
test('motion median resists outlier',()=>{const m=combineMotionEstimates([{dx:3,dy:-1,confidence:.8},{dx:4,dy:-1,confidence:.85},{dx:3,dy:0,confidence:.75},{dx:-8,dy:7,confidence:.2}]);assert.equal(m.dx,3);assert.equal(m.dy,-1);assert.ok(m.confidence>.55)});
test('projection sees approaching rain',()=>{const w=80,h=80,s=projectPointSeries(mask(w,h,19,35,10,10),w,h,{dx:5,dy:0,confidence:.9},{horizonMinutes:60,sourceStepMinutes:10,outputStepMinutes:5,radius:2});const e=detectNowcastEvent(s,{enterWetFraction:.1,exitWetFraction:.05,minConsecutive:1});assert.ok(e);assert.ok(e.startMinute>=20&&e.startMinute<=50)});
test('wetNear distinguishes wet and dry',()=>{const m=mask(20,20,8,8,4,4);assert.equal(wetNear(m,20,20,2,2,1),0);assert.ok(wetNear(m,20,20,9,9,1)>.5)});
