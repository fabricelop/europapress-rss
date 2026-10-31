'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync('windows/TTendenciasWebImages.cjs','utf8');
test('delivery wakes independently of the listener and never inherits the generation upload secret',()=>{
 const starts=[];let unref=0;
 const module={exports:{}};
 const requireMock=Object.assign(name=>name==='node:child_process'?{
  execFileSync:()=>{},spawn:(...args)=>{starts.push(args);return {on:()=>{},unref:()=>unref++};}
 }:name==='node:fs'?{readFileSync:()=>{throw Error('no watcher')}}:require(name),{main:null});
 vm.runInNewContext(source,{module,exports:module.exports,require:requireMock,__dirname:'/test',__filename:'/test/TTendenciasWebImages.cjs',
  process:{execPath:'/node',env:{TT_IMAGE_UPLOAD_SECRET:'must-not-leak',NORMAL:'kept'}},console,setTimeout,clearTimeout,URL});
 module.exports.wakePublisher();
 assert.equal(starts.length,1);assert.equal(unref,1);
 assert.equal(starts[0][0],'/node');assert.deepEqual(Array.from(starts[0][1]),['/test/TTendenciasWebImages.cjs','--watch']);
 assert.equal(starts[0][2].env.TT_IMAGE_UPLOAD_SECRET,undefined);
 assert.equal(starts[0][2].env.NORMAL,'kept');assert.equal(starts[0][2].detached,true);
});
test('an existing delivery watcher is reused without launching another process',()=>{
 let starts=0;const module={exports:{}};
 const requireMock=Object.assign(name=>name==='node:child_process'?{spawn:()=>{starts++;},execFileSync:()=>{}}:
 name==='node:fs'?{readFileSync:()=>JSON.stringify({pid:123,at:Date.now()})}:require(name),{main:null});
 vm.runInNewContext(source,{module,exports:module.exports,require:requireMock,__dirname:'/test',__filename:'/test/TTendenciasWebImages.cjs',process:{kill:()=>{}},console,setTimeout,clearTimeout,URL});
 module.exports.wakePublisher();assert.equal(starts,0);
});
