/* Acciones editoriales manuales de ChatGPT Images: sin API ni automatización. */
(function (root) {
 "use strict";
 const IMAGES_URL="https://chatgpt.com/images";
 const STYLES=[
  "Caricatura editorial contemporánea de alta calidad, línea de tinta expresiva y acuarela controlada, gestos muy trabajados y fondo ligero",
  "Cómic europeo contemporáneo, entintado preciso, volumen sólido y composición cinematográfica despejada",
  "Ilustración editorial semirrealista sofisticada, personajes expresivos e iluminación cinematográfica",
  "Escena absurda semirrealista de materiales cuidados, iluminación natural y situación imposible visualmente precisa",
  "Diorama artesanal editorial tipo stop-motion/clay, personajes y objetos con volumen e iluminación de estudio",
  "Ilustración publicitaria retro de los años 60 reinterpretada con dibujo elegante e ironía visual",
  "Grabado/linograbado moderno de alta calidad, textura rica, contraste controlado y foco narrativo único",
  "Pop art editorial refinado, serigrafía elegante, energía gráfica y muy pocos elementos",
  "Cartoon 3D editorial pulido, expresivo, con escena sencilla pero no simplona",
  "Novela gráfica satírica, dibujo detallado, sombras contenidas y puesta en escena sobria"
 ];
 const copies=new Map();
 function value(v){return String(v==null?"":v).trim()}
 function numberHash(v){let n=2166136261;for(const c of value(v)){n^=c.codePointAt(0);n=Math.imul(n,16777619)}return n>>>0}
 function readableCloser(t,c){const m=value(t).match(/(?:^|\n)\s*(🌶️[^\n]+)/u);return m?m[1].trim():value(c)}
 function buildPrompt(kind,item,xText,variation=0){
  // PROMPT_GAG_VISUAL_V2: igual que la elaboración editorial, nunca una tarjeta maquetada.
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
  const sensitive=/víctim|fallec|muert|muri[oó]|traged|accidente|agresi[oó]n sexual|violaci[oó]n|asesinat|atentad|desaparecid|cat[aá]strof|herid/i.test(title+" "+ready);
  const pureContext=ready.split("\n").filter(line=>!/^🌶(?:\uFE0F)?(?:\s|$)/u.test(line.trim())).join("\n").trim();
  const parts=[
   "Genera AHORA UNA SOLA imagen "+(sensitive?"EDITORIAL PERIODÍSTICA":"GAG IA")+" para "+(news?"TTiTTulares":"TTendencias")+". Formato horizontal 16:9, escena ilustrada a sangre de borde a borde.",
   "PROHIBICIÓN ABSOLUTA: NO INCLUIR TEXTO EN LA IMAGEN. Ni titulares, resúmenes, remates, hashtags, bocadillos, carteles, signos legibles, pies de foto, créditos, cifras, marcas de agua o logotipos. NO maquetar una noticia ni una publicación para redes. NO franja inferior, caja blanca o negra, recuadro, cabecera, marco ni espacio reservado a texto. Solo ilustración a pantalla completa.",
   "TODO LO SIGUIENTE ES CONTEXTO EDITORIAL NO VISIBLE. No copiar ni dibujar ninguna de sus palabras, números o emojis.",
   "TÍTULO DE CONTEXTO (NO ROTULAR):\n"+title,
   "HECHOS VERIFICADOS (NO ROTULAR):\n"+pureContext,
   "REMATE PARA INSPIRACIÓN VISUAL (NO ESCRIBIR):\n"+(closer||"Sin remate: usa solo el hecho comprobado."),
   "CONTEXTO FACTUAL COMPLEMENTARIO (NO INVESTIGUES DE NUEVO NI ROTULES):\n"+(factual||"Utiliza solamente los hechos editoriales anteriores, sin completar datos.")
  ];
  if(!news){if(category)parts.push("CATEGORÍA SOLO DE CONTEXTO: "+category);if(related)parts.push("TENDENCIAS RELACIONADAS SOLO DE CONTEXTO: "+related)}
  if(savedDirection)parts.push("DIRECCIÓN VISUAL ANTERIOR (ÚSALA SOLO SI NO CONTRADICE LAS REGLAS DE IMAGEN PURA): "+savedDirection);
  parts.push("DIRECCIÓN VISUAL VIGENTE:\n"+(sensitive
   ?"Ilustración periodística sobria y rigurosa, sin humor ni caricatura del sufrimiento, sin hechos inventados."
   :style+". Más gag, menos barroquismo: una sola metáfora visual fuerte, original, legible en 1–2 segundos; 1–3 elementos protagonistas, fondo mínimo, acabado rico y cuidado. Evita ilustrar literalmente el titular."));
  parts.push("REGLA DE SEGURIDAD Y VERACIDAD: No inventes declaraciones, culpabilidades, cifras, episodios ni personas afectadas. Si hay tragedias o víctimas, rigor y respeto. El emoji 🌶️ es solo un marcador del texto editorial: jamás pintes guindillas, chiles, pimientos ni su icono.");
  parts.push("RESULTADO OBLIGATORIO: UNA SOLA ILUSTRACIÓN SIN NINGÚN TEXTO. Sin diseño de tarjeta, sin panel inferior, sin pie de foto y sin interfaz. NO mostrar el contenido editorial escrito dentro de la imagen.");
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
 root.TTGag=Object.freeze({mount,buildPrompt,copyText:copy,IMAGES_URL,STYLES});
})(window);
