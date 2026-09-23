const CACHE="ttendencias-shell-v5";
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


self.addEventListener("push",event=>{
  let data={};
  try{data=event.data?event.data.json():{}}catch(_){data={body:event.data?event.data.text():""}}
  const title=data.title||"TTendencias";
  const options={
    body:data.body||"Hay un nuevo tuit listo para revisar.",
    tag:"ttendencias-ready",
    renotify:true,
    data:{url:data.url||"/ttendencias/preparados/"},
  };
  event.waitUntil(self.registration.showNotification(title,options));
});

self.addEventListener("notificationclick",event=>{
  event.notification.close();
  const target=event.notification?.data?.url||"/ttendencias/preparados/";
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
