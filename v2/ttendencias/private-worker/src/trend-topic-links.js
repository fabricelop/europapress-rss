// Conservative local matching: never group trends just for being about sport,
// politics, the same city, or a general celebrity. No external API or D1 read.
const OMIT=new Set(("la las los el del de en un una unos unas y o que por para con sin su sus al ante entre sobre tras desde hasta este esta estos estas es son fue han esta estan puede podria posible motivo causa origen tendencia tendencias explicacion principal confirmada confirmado hecho probable apuntan apunta impulsan noticia noticias actual actualidad rede redes social sociales conversaciones debate generaron genera generada nuevo nueva hoy ayer manana partido partidos jornada titularidad resultados resultado situacion encuentro publico publicada publicación publicada noticia evento eventos durante ante vuelve vuelve regreso regreso futbol liga equipo equipos juega jugar domingo sabado viernes lunes martes miercoles jueves españa espana madrid ciudad estadio temporada campeonato victoria gol goles" ).split(" "));

function words(value){
 const plain=String(value||"").replace(/([a-záéíóúüñ0-9])([A-ZÁÉÍÓÚÜÑ])/g,"$1 $2")
  .normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase();
 return [...new Set((plain.match(/[a-z0-9]{4,}/g)||[]).filter(x=>!OMIT.has(x)))];
}

export function clearlySameTrendTopic(origin,other){
 if(!origin||!other||origin.trend_id===other.trend_id)return false;
 const an=words(origin.name),bn=words(other.name);
 if(!an.length||!bn.length)return false;
 const a=words(origin.name+" "+String(origin.explanation||"").slice(0,950));
 const b=words(other.name+" "+String(other.explanation||"").slice(0,950));
 const aSet=new Set(a),bSet=new Set(b);
 const shared=a.filter(x=>bSet.has(x)&&x.length>=5);
 const coverage=shared.length/Math.max(1,Math.min(a.length,b.length));
 const aNamed=an.some(x=>bSet.has(x));
 const bNamed=bn.some(x=>aSet.has(x));
 // Identical descriptive hashtags or names with typographic differences.
 if(an.length===bn.length&&an.every(x=>bn.includes(x))&&an.join("").length>=7)return true;
 // Distinct names must be anchored in the same documented event, with
 // several uncommon words in common. One opponent alone is insufficient.
 return (aNamed&&bNamed&&shared.length>=2&&coverage>=0.20)||
   ((aNamed||bNamed)&&shared.length>=3&&coverage>=0.24);
}
