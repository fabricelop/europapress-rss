// Mi Mapa del Tiempo — Widget Scriptable (pantalla de inicio y bloqueo)
// En Mi Mapa: Ajustes → Widgets → Exportar resumen para Scriptable.
// En Archivos guarda MiMapaEstado.json en iCloud Drive / Scriptable.
// Este script no rastrea ubicaciones ni tiene acceso a datos privados de otra app.
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
  let name=widget.addText(String(data.place||"Sin lugar"));
  name.font=Font.boldSystemFont(family==="accessoryRectangular"?12:17);
  name.textColor=Color.white();
  name.lineLimit=2;
  widget.addSpacer(4);
  const active=Boolean(data.resting||data.tracking);
  const elapsed=active&&data.stayStart>0?
    Date.now()/1000-Number(data.stayStart):0;
  let stay=widget.addText(duration(elapsed));
  stay.font=Font.boldSystemFont(family==="accessoryRectangular"?14:22);
  stay.textColor=new Color("#FFFFFF");
  widget.addSpacer(3);
  const age=Math.max(0,Math.floor((Date.now()/1000-Number(data.generatedAt))/60));
  let detail=widget.addText((data.resting?"GPS pausado":data.tracking?"GPS activo":"GPS parado")+" · copia "+age+" min");
  detail.font=Font.systemFont(10);
  detail.textColor=new Color("#B9CFC9");
}else{
  let text=widget.addText("Exporta MiMapaEstado.json desde la aplicación");
  text.textColor=Color.white();
  text.font=Font.systemFont(13);
}
widget.addSpacer();
widget.refreshAfterDate=new Date(Date.now()+10*60*1000);
if(config.runsInWidget){ Script.setWidget(widget); }
else{ await widget.presentSmall(); }
Script.complete();
