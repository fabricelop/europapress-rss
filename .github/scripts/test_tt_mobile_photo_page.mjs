import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('docs/photo.html','utf8');
const found=html.match(/<script>([\s\S]*?)<\/script>/i);
assert(found,'Mobile photo script missing');
const script=found[1];

async function scenario(query, data, expectedUrl) {
  const nodes=new Map();
  const element=id=>{
    if(!nodes.has(id))nodes.set(id,{
      style:{display:'none'},hidden:true,disabled:true,src:'',href:'',
      textContent:'',addEventListener(){},setAttribute(){},
    });
    return nodes.get(id);
  };
  const fetched=[];
  const ctx={
    location:{search:query},
    URL,URLSearchParams,Date,Math,
    document:{getElementById:element},
    navigator:{},ClipboardItem:undefined,
    fetch:async url=>{
      fetched.push(String(url));
      const key=Object.keys(data).find(k=>String(url).includes(k));
      return {ok:Boolean(key),json:async()=>data[key]};
    },
    console,
  };
  vm.runInNewContext(script,ctx);
  // Let the async fetches and start() settle.
  for(let i=0;i<10;i++)await new Promise(resolve=>setImmediate(resolve));
  const photo=element('photo'),status=element('status');
  if(expectedUrl) {
    assert.equal(photo.src,expectedUrl,'Must display only the verified archive image');
    assert.equal(photo.style.display,'block','Image must be visible for iPhone press-and-hold');
    assert.equal(element('copy').disabled,false,'Copy button must be active');
    assert.equal(element('original').href,expectedUrl,'Original image link missing');
  } else {
    assert.equal(photo.style.display,'none','AI image must never masquerade as an archive');
    assert.match(status.textContent,/No encuentro una fotografía de archivo/);
  }
  return {url:photo.src,requests:fetched.length};
}
const id='d851a532612e';
await scenario('?app=ttendencias&id='+id+'&rev=0',{
  'trends/telegram-image-deliveries.json':{items:[{
    event_id:id,revision:0,delivery_key:id+':r0:readonly',
    is_photo:true,image_url:'https://images.example.org/penta.jpg',
    title:'Penta',status:'sent'
  }]}
},'https://images.example.org/penta.jpg');
await scenario('?app=ttendencias&id='+id+'&rev=0',{
  'trends/telegram-image-deliveries.json':{items:[{
    event_id:id,revision:0,delivery_key:id+':r0:ai-sha',
    is_photo:true,image_url:'https://raw.githubusercontent.com/org/repo/generated-images/gag.jpg',
    archive_materialized_url:'https://raw.githubusercontent.com/org/repo/archive-images/archive.jpg',
    title:'Penta',status:'sent'
  }]}
},'https://raw.githubusercontent.com/org/repo/archive-images/archive.jpg');
await scenario('?app=ttendencias&id='+id+'&rev=0',{
  'trends/telegram-image-deliveries.json':{items:[{
    event_id:id,revision:0,delivery_key:id+':r0:ai-sha',
    is_photo:true,image_url:'https://raw.githubusercontent.com/org/repo/generated-images/gag.jpg'
  }]},
  'trends/explained.json':{items:[]}
},'');
await scenario('?id=abc123&rev=1',{
  'ttittulares/prepared.json':{items:[{
    event_id:'abc123',revision:1,title:'Noticia verificada',
    archive_image:{url:'https://example.org/news.jpg',generated:false}
  }]}
},'https://example.org/news.jpg');
// A provisional Telegram photo can exist BEFORE the editorial READY file.
await scenario('?id=early123&rev=1',{
 'ttittulares/prepared.json':{items:[]},
 'telegram/ttittulares-deliveries.json':{items:[{
   event_id:'early123',revision:1,delivery_key:'early123:r1:readonly',
   status:'sent',final:false,is_photo:true,
   image_url:'https://img.example.org/first-provisional.jpg',
   telegram_message_id:1011
 }]}
},'https://img.example.org/first-provisional.jpg');
// When the article photo arrives after a text alert, retrieve exactly the
// original archive URL stored on the same editorial ledger row.
await scenario('?id=late123&rev=1',{
 'ttittulares/prepared.json':{items:[]},
 'telegram/ttittulares-deliveries.json':{items:[{
   event_id:'late123',revision:2,delivery_key:'late123:r1:readonly',
   status:'sent',final:true,is_photo:false,
   telegram_message_id:2011,archive_telegram_message_id:2012,
   archive_image_url:'https://img.example.org/late-archive.jpg'
 }]}
},'https://img.example.org/late-archive.jpg');
console.log('TT_MOBILE_ARCHIVE_PHOTO_TEST_OK');
