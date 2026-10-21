const CACHE="ttendencias-shell-v4-pending-close-guard";
const SHELL=["/ttendencias/manifest.webmanifest","/ttendencias/icon.svg"];

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

  // Las navegaciones de la app nunca se sirven desde la caché del SW.
  // Esto evita que una PWA instalada conserve una shell antigua.
  if(event.request.mode==="navigate"){
    event.respondWith(fetch(event.request,{cache:"no-store"}));
    return;
  }

  event.respondWith(
    fetch(event.request,{cache:"no-store"}).then(r=>r).catch(()=>caches.match(event.request).then(r=>r||Response.error()))
  );
});
