/* Acciones editoriales manuales de ChatGPT Images: sin API ni automatización. */
(function (root) {
 "use strict";
 const IMAGES_URL="https://chatgpt.com/images";
 const STYLES=[
  "caricatura editorial de prensa, personajes expresivos y objetos simbólicos desproporcionados",
  "collage fotográfico surrealista, montaje imposible y contraste visual absurdo",
  "pop art satírico, colores intensos y composición de cómic",
  "viñeta de humor gráfico con metáfora visual ingeniosa y líneas expresivas",
  "escena cinematográfica de comedia absurda, iluminación teatral y atrezo exagerado",
  "maqueta 3D satírica artesanal con miniaturas y objetos gigantes",
  "cartel retro de sátira ilustrada, composición contundente y textura impresa",
  "ilustración conceptual surrealista, perspectiva imposible y humor inteligente"
 ];
 const copies=new Map();
 function value(v){return String(v==null?"":v).trim()}
 function numberHash(v){let n=2166136261;for(const c of value(v)){n^=c.codePointAt(0);n=Math.imul(n,16777619)}return n>>>0}
 function readableCloser(t,c){if(value(c))return value(c);const m=value(t).match(/(?:^|\n)\s*(🌶️[^\n]+)/u);return m?m[1].trim():""}
 function buildPrompt(kind,item,xText,variation=0){
  const news=kind==="news";
  const title=value(news?item.title:(item.group_title||item.name||item.display_name||item.term_normalized));
  const ready=value(xText||(news?item.tweet?.text:item.explanation));
  const closer=readableCloser(ready,news?(item.tweet?.remate||item.remate):item.closer_text);
  const factual=value(item.factual_summary||item.verified_factual_summary||item.context_summary||item.news_summary||item.news_title);
  const category=value(item.category||item.editorial_category);
  const related=Array.isArray(item.trend_names)?item.trend_names.filter(Boolean).join(", "):"";
  const savedDirection=value(item.visual_direction||item.image_direction||item.ai_image_direction);
  const id=value(item.event_id||item.id||item.term_normalized||title);
  const style=STYLES[(numberHash(id)+Math.max(0,Number(variation)||0))%STYLES.length];
  const parts=[
   "Genera AHORA UNA SOLA imagen GAG IA original para "+(news?"TTiTTulares":"TTendencias")+". Usa la herramienta de imágenes de ChatGPT.",
   "TÍTULO / "+(news?"NOTICIA":"TENDENCIA")+":\n"+title,
   "TEXTO EXACTO YA CERRADO (NO LO REESCRIBAS):\n"+ready,
   "REMATE EXACTO (INSPIRA EL GAG, NO LO REESCRIBAS):\n"+(closer||"No consta un remate separado; respeta el texto exacto."),
   "CONTEXTO FACTUAL COMPLEMENTARIO (NO INVESTIGUES DE NUEVO):\n"+(factual||"No hay resumen complementario: utiliza exclusivamente los hechos del texto exacto, sin completar datos.")
  ];
  if(!news){if(category)parts.push("CATEGORÍA: "+category);if(related)parts.push("TENDENCIAS RELACIONADAS: "+related)}
  if(savedDirection)parts.push("DIRECCIÓN VISUAL GUARDADA: "+savedDirection);
  parts.push("DIRECCIÓN VISUAL DE ESTA GENERACIÓN:\n"+style+". Construye un gag visual creativo a partir de la ironía del remate: metáfora, contradicción, exageración y una situación inesperada. NO ilustres literalmente el titular. Si hay personas reales, puedes caricaturizarlas de manera reconocible sin falsear hechos.");
  parts.push("REGLAS:\n- Genera una sola imagen terminada, ingeniosa, cómica y satírica, no una respuesta de texto ni varias propuestas.\n- Fidelidad estricta a los hechos, protagonistas, lugares y fechas indicados. No inventes declaraciones, culpabilidades, cifras ni eventos.\n- El chiste debe ser visual, no un titular sobreimpreso. Evita rótulos largos, textos, marcas de agua y logotipos innecesarios.\n- En tragedias, accidentes, atentados o desastres con víctimas, no ridiculices a las víctimas ni su sufrimiento.\n- Composición clara de alta calidad, pensada para publicar en X, horizontal 16:9.\n- No cambies el tuit ni el remate: SOLO genera la imagen.");
  return parts.join("\n\n");
 }
 async function copy(txt){
  if(root.navigator?.clipboard?.writeText){try{await root.navigator.clipboard.writeText(txt);return true}catch(_){}}
  try{const area=root.document.createElement("textarea");area.value=txt;area.setAttribute("readonly","");area.style.position="fixed";area.style.left="-9999px";root.document.body.appendChild(area);area.select();area.setSelectionRange(0,area.value.length);const ok=root.document.execCommand("copy");area.remove();if(ok)return true}catch(_){}
  root.prompt("Copia este texto:",txt);return false;
 }
 function mount(container,options){
  if(!container)return;
  container.querySelectorAll("[data-ttgag]").forEach(node=>node.remove());
  const item=options.item||{},kind=options.kind==="news"?"news":"trend";
  const content=value(options.xText||(kind==="news"?item.tweet?.text:item.explanation));
  if(!content)return;
  const key=kind+":"+value(item.event_id||item.id||item.term_normalized||item.title||item.name);
  const notify=typeof options.feedback==="function"?options.feedback:()=>{};
  function button(label,action){const b=root.document.createElement("button");b.type="button";b.className="btn ttGagButton";b.dataset.ttgag="1";b.textContent=label;b.addEventListener("click",action);container.appendChild(b)}
  function link(label,url){const a=root.document.createElement("a");a.className="btn ttGagButton";a.dataset.ttgag="1";a.href=url;a.target="_blank";a.rel="noopener noreferrer";a.textContent=label;container.appendChild(a)}
  button("Copiar prompt GAG",async()=>{const n=copies.get(key)||0;const ok=await copy(buildPrompt(kind,item,content,n));if(ok){copies.set(key,n+1);notify("Prompt GAG copiado · versión "+(n+1)+". Pégalo en ChatGPT Images.")}});
  link("Chat Images",IMAGES_URL);
  if(options.includeX!==false){button("Copiar en X",async()=>{if(await copy(content))notify("Texto para X copiado")});link("Abrir en X","https://twitter.com/intent/tweet?text="+encodeURIComponent(content))}
 }
 root.TTGag=Object.freeze({mount,buildPrompt,IMAGES_URL,STYLES});
})(window);
