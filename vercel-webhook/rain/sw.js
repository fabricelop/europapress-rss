const CACHE='raineta-v55';
const ASSETS=['/rain/','/rain/index.html','/rain/app.js?v=0.17.29','/rain/core.js','/rain/radar-core.js','/rain/manifest.webmanifest','/rain/icon.svg'];

self.addEventListener('install',event=>{
  event.waitUntil(
    caches.open(CACHE)
      .then(cache=>cache.addAll(ASSETS))
      .catch(()=>{})
      .then(()=>self.skipWaiting())
  );
});

self.addEventListener('activate',event=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    await Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch',event=>{
  const request=event.request;
  if(request.method!=='GET')return;
  const url=new URL(request.url);
  if(url.origin!==location.origin||url.pathname.startsWith('/api/'))return;

  const isRainAsset=url.pathname==='/rain/'||url.pathname==='/rain'||url.pathname.startsWith('/rain/');
  if(!isRainAsset)return;

  event.respondWith((async()=>{
    try{
      const fresh=await fetch(request,{cache:'no-store'});
      if(fresh&&fresh.ok){
        const cache=await caches.open(CACHE);
        cache.put(request,fresh.clone()).catch(()=>{});
      }
      return fresh;
    }catch(error){
      const cached=await caches.match(request);
      if(cached)return cached;
      if(request.mode==='navigate'){
        const shell=await caches.match('/rain/index.html');
        if(shell)return shell;
      }
      throw error;
    }
  })());
});
