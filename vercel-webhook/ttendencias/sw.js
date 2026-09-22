const CACHE="ttendencias-shell-v1";
const SHELL=["/ttendencias/","/ttendencias/index.html","/ttendencias/manifest.webmanifest","/ttendencias/icon.svg"];
self.addEventListener("install",event=>{event.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).catch(()=>{}));self.skipWaiting()});
self.addEventListener("activate",event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));self.clients.claim()});
self.addEventListener("fetch",event=>{
  const u=new URL(event.request.url);
  if(event.request.method!=="GET"||u.pathname.startsWith("/api/"))return;
  event.respondWith(fetch(event.request).then(r=>{
    const copy=r.clone();caches.open(CACHE).then(c=>c.put(event.request,copy)).catch(()=>{});
    return r;
  }).catch(()=>caches.match(event.request).then(r=>r||caches.match("/ttendencias/index.html"))));
});
