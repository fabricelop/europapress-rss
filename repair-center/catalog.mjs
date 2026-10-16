// Catálogo explícito y cerrado: nunca se ejecutan nombres de workflow aportados por el cliente.
export const PROJECTS = [
  {id:'ttittulares', name:'TTiTTulares', processes:[
    {id:'radar',name:'Radar de noticias',mode:'cloud',workflow:'radar-no-d1.yml',check:'ttRadar'},
    {id:'editorial',name:'Elaboración de noticias',mode:'inspect',check:'ttEditorial',note:'La elaboración efectiva requiere una sesión editorial ChatGPT; no hay ejecutor cloud autónomo confirmado.'},
    {id:'images',name:'Preparación de imágenes IA / Listas',mode:'cloud',workflow:'repair-ttittulares-listas.yml',check:'ttImages',note:'Encola trabajos; la generación IA puede necesitar el PC.'},
    {id:'windows',name:'Puente de imágenes en Windows',mode:'local',check:'pc',note:'Revisa la tarea local configurada; PC apagado = pendiente.'},
    {id:'telegram',name:'Antiguo envío Telegram',mode:'disabled',note:'El envío editorial Telegram está desactivado en TTActualidad; no reactivarlo sin autorización.'}
  ]},
  {id:'ttendencias',name:'TTendencias',processes:[
    {id:'radar',name:'Captura Top 30 y radar',mode:'cloud',workflow:'ttendencias-refresh.yml',check:'trRadar'},
    {id:'editorial',name:'Explicaciones y reelaboraciones',mode:'inspect',check:'trEditorial',note:'La redacción requiere ejecución editorial real; no equivale a mover un trigger.'},
    {id:'images',name:'Reparar Explicadas / imágenes',mode:'cloud',workflow:'repair-ttendencias-explicadas.yml',check:'trImages'},
    {id:'windows',name:'Puente de imágenes en Windows',mode:'local',check:'pc'},
    {id:'telegram',name:'Antiguo envío Telegram',mode:'disabled',note:'Desactivado en la configuración actual.'}
  ]},
  {id:'ttactualidad',name:'TTActualidad',processes:[
    {id:'website',name:'Estado web / salud',mode:'inspect',check:'ttWebsite'},
    {id:'tests',name:'Pruebas de integridad de la web',mode:'cloud',workflow:'ttactualidad-v8-tests.yml',note:'Pruebas, no despliegue automático.'},
    {id:'decisions',name:'Acciones editoriales y Listas',mode:'inspect',note:'Revisión de estado; no repetir acciones irreversibles sin autorización.'}
  ]},
  {id:'selorecordamos',name:'SeLoRecordamos',processes:[
    {id:'editorial',name:'Solicitudes pendientes',mode:'inspect',check:'slrEditorial'},
    {id:'health',name:'Verificación no invasiva',mode:'cloud',workflow:'tt-slr-health-verification.yml'},
    {id:'telegram',name:'Pruebas de entrega Telegram',mode:'cloud',workflow:'selorecordamos-telegram-delivery-tests.yml',note:'Ejecuta tests, no reenvía mensajes.'},
    {id:'windows',name:'Procesos locales Windows',mode:'local',check:'pc'}
  ]},
  {id:'raineta',name:'RainETA',processes:[
    {id:'radar',name:'Prueba de fuentes radar',mode:'cloud',workflow:'raineta-radar-feasibility.yml',note:'Diagnóstico, no altera la predicción.'},
    {id:'website',name:'Pruebas estáticas',mode:'cloud',workflow:'rain-static-ci.yml'},
    {id:'ios',name:'App iPhone y widget',mode:'inspect',note:'No es posible reparar una app instalada remotamente con una acción GitHub.'}
  ]},
  {id:'fabcalendar',name:'FabCalendar',processes:[
    {id:'calendar',name:'Eventos y tareas',mode:'inspect',note:'Integración con repositorio/servidor privado pendiente; sin acciones de modificación.'},
    {id:'sync',name:'Sincronización',mode:'inspect',note:'Sin credenciales ni conector operativo de reparación.'}
  ]},
  {id:'aquiestuve',name:'AquíEstuve',processes:[
    {id:'ios',name:'App iPhone / cierres / mapa',mode:'inspect',note:'El móvil requiere logs de diagnóstico y nueva compilación firmada.'},
    {id:'windows',name:'Compilación e instalación Windows',mode:'local',check:'pc'}
  ]},
  {id:'pokerpilot',name:'PokerPilot',processes:[
    {id:'study',name:'Motor de estudio y vídeo',mode:'inspect',note:'Sin ejecutor remoto de reparación conectado.'}
  ]},
  {id:'lotolab',name:'LotoLab',processes:[
    {id:'app',name:'Aplicación HTML local',mode:'inspect',note:'Sin acceso al archivo local desde la nube.'}
  ]},
  {id:'widgetlluvia',name:'Widget lluvia iPhone',processes:[
    {id:'widget',name:'Widget / actualización',mode:'inspect',note:'La reparación de la extensión iOS requiere versión compilada y diagnóstico en dispositivo.'}
  ]}
];
export const TARGETS = new Map(PROJECTS.flatMap(p => p.processes.map(x => [`${p.id}.${x.id}`,{...x,project:p.id,target:`${p.id}.${x.id}`}])));
export const cloudTargets = [...TARGETS.values()].filter(x=>x.mode==='cloud');
