// Mi Mapa del Tiempo — Widget Scriptable (pantalla de inicio y bloqueo)
// En Mi Mapa: Ajustes → Widgets → Exportar resumen para Scriptable.
// En Archivos guarda MiMapaEstado.json en iCloud Drive / Scriptable.
// El tiempo es el del ÚLTIMO resumen exportado; Scriptable no lee el GPS
// ni detecta por sí solo los cambios de zona.
const fm=FileManager.iCloud();
const filepath=fm.joinPath(fm.documentsDirectory(),"MiMapaEstado.json");
const widget=new ListWidget();
widget.url="mimapadeltiempo://mapa";
widget.backgroundColor=new Color("#133B36");
widget.addSpacer(3);
const title=widget.addText("MI MAPA DEL TIEMPO");
title.font=Font.boldSystemFont(11);
title.textColor=new Color("#70DFD5");
widget.addSpacer(4);
let data=null;
try {
  if(fm.fileExists(filepath)){
    await fm.downloadFileFromiCloud(filepath);
    data=JSON.parse(fm.readString(filepath));
  }
}catch(e){}
const family=config.widgetFamily||"small";
function duration(seconds){
  const n=Math.max(0,Math.floor(seconds));
  const h=Math.floor(n/3600),m=Math.floor(n%3600/60),s=n%60;
  return h>0?h+" h "+m+" min":m+" min "+s+" s";
}
if(data) {
  const count=Math.max(0,Number(data.cellCount)||0);
  const isZone=data.placeType==="zona" || (data.placeType===undefined && count>1);
  const displayName=String(data.place||"Cuadrícula sin nombre");
  const header=widget.addText(displayName);
  header.font=Font.boldSystemFont(family==="accessoryRectangular"?12:17);
  header.textColor=Color.white();
  header.lineLimit = 2;
  widget.addSpacer(3);
  const kind=widget.addText(isZone?
      ("ZONA · "+count+" cuadrícula"+(count===1?"":"s")):
      "CUADRÍCULA INDEPENDIENTE");
  kind.font=Font.boldSystemFont(9);
  kind.textColor=new Color("#70DFD5");
  widget.addSpacer(4);
  const seconds=isZone?Number(data.zoneSeconds||0):Number(data.cellSeconds||0);
  const hasTotal=Number.isFinite(seconds) && data.schema>=2;
  const main=widget.addText(hasTotal?duration(seconds):"Resumen anterior");
  main.font=Font.boldSystemFont(family==="accessoryRectangular"?14:21);
  main.textColor=Color.white();
  widget.addSpacer(3);
  const age=Math.max(0,Math.floor((Date.now()/1000-Number(data.generatedAt||0))/60));
  const mode=data.resting?"Pausa GPS":data.tracking?"GPS activo":"GPS detenido";
  const detail=widget.addText(mode+" · última copia "+age+" min");
  detail.font=Font.systemFont(10);
  detail.textColor=new Color("#B9CFC9");
}else{
  const missing=widget.addText("Exporta MiMapaEstado.json desde Mi Mapa");
  missing.textColor=Color.white();
  missing.font=Font.systemFont(12);
}

widget.addSpacer();
widget.refreshAfterDate=new Date(Date.now()+10*60*1000);
if(config.runsInWidget){ Script.setWidget(widget); }
else{ await widget.presentSmall(); }
Script.complete();
