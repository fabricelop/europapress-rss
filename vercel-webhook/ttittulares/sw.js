const CACHE="ttittulares-shell-v3";
const SHELL=["/ttittulares/","/ttittulares/index.html","/ttittulares/manifest.webmanifest","/ttittulares/icon.svg"];
self.addEventListener("install",e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",e=>{const u=new URL(e.request.url);if(u.origin!==location.origin||u.pathname.startsWith("/api/"))return;
 e.respondWith(fetch(e.request).then(r=>{const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));return r}).catch(()=>caches.match(e.request)));
});
self.addEventListener("push",e=>{
 let data={};try{data=e.data?e.data.json():{}}catch(_){}
 const title=data.title||"TTiTTulares";
 const options={body:data.body||"Hay noticias listas para publicar",icon:"/ttittulares/icon.svg",badge:"/ttittulares/icon.svg",tag:data.batch_id||data.event_id||"ttittulares-ready",renotify:true,data:{url:data.url||"/ttittulares/"}};
 e.waitUntil(self.registration.showNotification(title,options));
});
self.addEventListener("notificationclick",e=>{
 e.notification.close();const url=e.notification.data?.url||"/ttittulares/";
 e.waitUntil(clients.matchAll({type:"window",includeUncontrolled:true}).then(list=>{
  for(const c of list){if("focus" in c){c.navigate(url);return c.focus()}}
  return clients.openWindow?clients.openWindow(url):null
 }));
});
