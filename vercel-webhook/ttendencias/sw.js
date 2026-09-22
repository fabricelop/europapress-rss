const CACHE="ttendencias-shell-v3";
const SHELL=["/ttendencias/","/ttendencias/index.html","/ttendencias/preparados/","/ttendencias/manifest.webmanifest","/ttendencias/icon.svg"];

self.addEventListener("install",event=>{
  event.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).catch(()=>{}));
  self.skipWaiting();
});

self.addEventListener("activate",event=>{
  event.waitUntil(
    caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener("fetch",event=>{
  if(event.request.method!=="GET")return;
  const u=new URL(event.request.url);

  // Nunca interceptar GitHub RAW ni las APIs. Los JSON editoriales deben
  // llegar siempre frescos y nunca recibir HTML como fallback por error.
  if(u.origin!==self.location.origin || u.pathname.startsWith("/api/"))return;
  if(!u.pathname.startsWith("/ttendencias"))return;

  event.respondWith(
    fetch(event.request).then(r=>{
      const copy=r.clone();
      caches.open(CACHE).then(c=>c.put(event.request,copy)).catch(()=>{});
      return r;
    }).catch(async()=>{
      const exact=await caches.match(event.request);
      if(exact)return exact;
      if(event.request.mode==="navigate")return caches.match("/ttendencias/index.html");
      return Response.error();
    })
  );
});
