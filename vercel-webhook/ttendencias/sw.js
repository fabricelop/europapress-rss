const CACHE="ttendencias-shell-explain-v1";
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


self.addEventListener("push",event=>{
  let data={};
  try{data=event.data?event.data.json():{}}catch(_){data={body:event.data?event.data.text():""}}
  const title=data.title||"TTendencias";
  const options={
    body:data.body||"Hay nuevos Trending Topics en España.",
    tag:"ttendencias-top10",
    renotify:false,
    silent:true,
    data:{url:data.url||"/ttendencias/"},
  };
  event.waitUntil(self.registration.showNotification(title,options));
});

self.addEventListener("notificationclick",event=>{
  event.notification.close();
  const target=event.notification?.data?.url||"/ttendencias/";
  event.waitUntil((async()=>{
    const windows=await self.clients.matchAll({type:"window",includeUncontrolled:true});
    for(const client of windows){
      if("focus" in client){
        if("navigate" in client)await client.navigate(target);
        return client.focus();
      }
    }
    if(self.clients.openWindow)return self.clients.openWindow(target);
  })());
});
