// Backend isolated from Telegram: never accept unverified Telegram updates here.

const INSTAGRAM_TOPIC_TAGS=[
  [/\btrump\b/i, "#DonaldTrump"],
  [/\beeuu\b|\bestados unidos\b|\bestadounidens\w*/i, "#EstadosUnidos"],
  [/\biran\b|\birani\w*/i, "#Iran"],
  [/\belecciones?\b|\blegislativas\b|\bcampana electoral\b/i, "#Elecciones"],
  [/\bcombustibles?\b|\bgasolina\b|\bcarburantes?\b/i, "#Combustibles"],
  [/\bpremio nobel de la paz\b|\bnobel de la paz\b/i, "#PremioNobelDeLaPaz"],
  [/\bnavi pillay\b/i, "#NaviPillay"],
  [/\bsudafrica\b|\bsudafrican\w*/i, "#Sudafrica"],
  [/\bderecho internacional\b/i, "#DerechoInternacional"],
  [/\bpromover la paz\b|\bpaloma de la paz\b|\bpaz\b/i, "#Paz"],
  [/\brenoir\b/i, "#Renoir"],
  [/\bfrancia\b|\bfrances\w*/i, "#Francia"],
  [/\barte\b|\bcuadros?\b|\bpinturas?\b|\bmuseos?\b/i, "#Arte"],
  [/\bcuadros?\b|\bpinturas?\b/i, "#Pintura"],
  [/\bmuseos?\b/i, "#Museos"],
  [/\bshakira\b/i, "#Shakira"],
  [/\bla revuelta\b/i, "#LaRevuelta"],
  [/\bbroncano\b/i, "#DavidBroncano"],
  [/\breal madrid\b/i, "#RealMadrid"],
  [/\bbar[cç]a\b|\bfc barcelona\b/i, "#FCBarcelona"],
  [/\beuroliga\b/i, "#Euroliga"],
  [/\bpartizan\b/i, "#Partizan"],
  [/\batletico de madrid\b/i, "#AtleticoDeMadrid"],
  [/\blamine yamal\b/i, "#LamineYamal"],
  [/\balcaraz\b/i, "#CarlosAlcaraz"],
  [/\bsinner\b/i, "#JannikSinner"],
  [/\bverstappen\b/i, "#MaxVerstappen"],
  [/\balonso\b/i, "#FernandoAlonso"],
  [/\bformula 1\b|\bf1\b/i, "#Formula1"],
  [/\btenis\b/i, "#Tenis"],
  [/\bbaloncesto\b|\bcanasta\b|\bpartizan\b|\beuroliga\b/i, "#Baloncesto"],
  [/\bfutbol\b|\bgol\b|\bliga de campeones\b/i, "#Futbol"],
  [/\bcine\b|\bpelicula\b|\boscar\b/i, "#Cine"],
  [/\bconcierto\b|\bcantante\b|\bmusica\b/i, "#Musica"],
  [/\bserie\b|\bprograma de television\b|\btelevision\b/i, "#Television"],
  [/\bgobierno\b|\bcongreso\b|\belecciones?\b|\bministro\b|\bpolitica\b/i, "#Politica"],
  [/\bsanchez\b/i, "#PedroSanchez"],
  [/\bfeijoo\b/i, "#AlbertoNunezFeijoo"],
  [/\brufian\b/i, "#GabrielRufian"],
  [/\bdesahucio\b|\balquiler\b|\bvivienda\b/i, "#Vivienda"],
  [/\btribunal\b|\bsentencia\b|\bfiscalia\b/i, "#Justicia"],
  [/\binteligencia artificial\b|\btecnologia\b/i, "#Tecnologia"],
  [/\bclima\b|\btemperaturas?\b|\bmeteorologia\b/i, "#Meteorologia"],
  [/\blluvia\b|\btormenta\b/i, "#Lluvia"],
  [/\binmigracion\b|\bmigracion\b|\bice\b/i, "#Migracion"],
  [/\beconomia\b|\binflacion\b|\bprecios\b/i, "#Economia"],
  [/\brally\b|\brali\b/i, "#Rally"],
  [/\bmallorca\b/i, "#Mallorca"],
  [/\baccidente\b|\bsiniestro\b/i, "#Accidente"],
  [/\bterremoto\b|\bsismo\b/i, "#Terremoto"],
  [/\bpamplona\b/i, "#Pamplona"],
  [/\bnavarra\b/i, "#Navarra"],
  [/\bbarcelona\b/i, "#Barcelona"],
  [/\bmadrid\b/i, "#Madrid"],
  [/\bmalaga\b/i, "#Malaga"],
  [/\btoledo\b/i, "#Toledo"],
  [/\baragon\b|\bsijena\b/i, "#Aragon"],
  [/\bsijena\b/i, "#Sijena"],
  [/\btrenes?\b|\bferrocarril\b/i, "#Trenes"],
  [/\btransportes?\b|\btrafico\b/i, "#Transporte"],
  [/\bagricultor\w*|\btractor\w*|\bcampo\b/i, "#Agricultura"],
  [/\btractorada\b/i, "#Tractorada"],
  [/\bsalud mental\b/i, "#SaludMental"],
  [/\bhospital\b|\bmedic\w*|\bsanitari\w*/i, "#Sanidad"],
  [/\bcnmc\b/i, "#CNMC"],
  [/\bcentros? de datos\b/i, "#CentrosDeDatos"],
  [/\benergi\w*|\brenovable\w*/i, "#Energia"],
  [/\brenovable\w*/i, "#Renovables"],
  [/\bbanco de espana\b/i, "#BancoDeEspana"],
  [/\bpib\b|\bcrecimiento economico\b/i, "#PIB"],
  [/\binflacion\b/i, "#Inflacion"],
  [/\bibi\b|\bimpuest\w*/i, "#Impuestos"],
  [/\bpisos? turistico\w*|\bturismo\b/i, "#Turismo"],
  [/\bpedro sanchez\b/i, "#PedroSanchez"],
  [/\bpp\b|\bpartido popular\b/i, "#PartidoPopular"],
  [/\bpsoe\b/i, "#PSOE"],
  [/\bfiscalia\b/i, "#Fiscalia"],
  [/\btribunal supremo\b/i, "#TribunalSupremo"],
  [/\bindult\w*/i, "#Indulto"],
  [/\bnacionalizad\w*|\bnacionalidad\b/i, "#Nacionalidad"],
  [/\bguardia civil\b/i, "#GuardiaCivil"],
  [/\bmaltrato animal\b|\babandono animal\b/i, "#ProteccionAnimal"],
  [/\bperros?\b/i, "#Perros"],
  [/\brefn\b/i, "#NicolasWindingRefn"],
  [/\bsitges\b/i, "#Sitges"],
  [/\bpeliculas?\b|\bcine\b/i, "#Cine"],
  [/\bdeporte\w*/i, "#Deportes"],
  [/\bmoto\w*|\bcoche\w*|\bautomov\w*/i, "#Motor"],
  [/\bpresupuesto\w*|\bdeuda\b|\bfinanzas?\b/i, "#Finanzas"],
  [/\bunion europea\b|\bbruselas\b/i, "#UnionEuropea"],
  [/\bukrania\b/i, "#Ucrania"],
  [/\brusia\b/i, "#Rusia"],
  [/\bgaza\b/i, "#Gaza"],
  [/\bseguridad\b|\bpolicia\b/i, "#Seguridad"],
  [/\bcultura\b|\bpatrimonio\b/i, "#Cultura"],
  [/\beducacion\b|\buniversidad\b/i, "#Educacion"],
  [/\bempresa\w*|\bnegocio\w*/i, "#Empresas"],
];
function instagramCaption(raw) {
  // Meta-publication boundary: also fixes already-delivered Telegram snapshots
  // without rewriting the source caption stored for idempotency in D1.
  let value=String(raw||"").trim()
    .replace(/^@?ttactualidad\s*[:—–-]?\s*/i,"")
    .replace(/(?:^|\s)#(?:TTActualidad|Actualidad)\b/gi," ")
    .trim();
  const present=new Set((value.match(/(?<!\w)#[\p{L}\d_]+/gu)||[]).map(x=>x.toLowerCase()));
  const factual=value.split(/\n\s*\n/,1)[0];
  const normalized=factual.normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase();
  const tags=[];
  for(const [pattern,tag] of INSTAGRAM_TOPIC_TAGS) {
    if(tags.length+present.size>=5)break;
    if(pattern.test(normalized)&&!present.has(tag.toLowerCase())) {
      tags.push(tag);
      present.add(tag.toLowerCase());
    }
  }
  // For newly emerging names not yet in the rules, tag only proper names
  // occurring literally in the approved factual sentence.
  if(tags.length+present.size<2) {
    const named=factual.match(/\b[A-ZÁÉÍÓÚÑ][a-záéíóúñü]{2,}(?:\s+(?:de|del|la|las|los|y)\s+)?[A-ZÁÉÍÓÚÑ][a-záéíóúñü]{2,}(?:\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñü]{2,})?/gu)||[];
    for(const item of named) {
      if(tags.length+present.size>=3)break;
      const words=item.normalize("NFD").replace(/[\u0300-\u036f]/g,"").split(/\s+/).filter(Boolean);
      const tag="#"+words.map(w=>w[0].toUpperCase()+w.slice(1)).join("");
      if(tag.length<=35&&!present.has(tag.toLowerCase())) {
        tags.push(tag);present.add(tag.toLowerCase());
      }
    }
  }
  for(let i=tags.length;i>0;i--) {
    const result=value+"\n\n"+tags.slice(0,i).join(" ");
    if(result.length<=2200)return result;
  }
  return value;
}

const IMG=/^https:\/\/raw\.githubusercontent\.com\/fabricelop\/europapress-rss\/main\/(?:trends|ttittulares)\/(?:generated-images|instagram-images)\/[A-Za-z0-9._-]+\.jpe?g$/;
const answer=(v,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{"content-type":"application/json","cache-control":"no-store"}});
function constantTimeEqual(a,b){const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return false;let diff=0;for(let i=0;i<x.length;i++)diff|=x[i]^y[i];return diff===0;}
function isActive(env){return env.INSTAGRAM_PUBLISH_ENABLED==="1"&&Boolean(env.INSTAGRAM_INTERNAL_SECRET&&env.INSTAGRAM_PAGE_ACCESS_TOKEN&&env.IG_DB);}
function authorize(req,env){const secret=String(env.INSTAGRAM_INTERNAL_SECRET||"");return secret.length>=32&&constantTimeEqual(req.headers.get("authorization")||"","Bearer "+secret);}
function inputCheck(b){
  const source=String(b?.source||""),id=String(b?.event_id||""),revision=Number(b?.revision??0);
  const mid=Number(b?.telegram_message_id||0),image=String(b?.image_url||""),caption=String(b?.caption||"").trim();
  if(!["ttittulares","ttendencias"].includes(source)||!/^[a-zA-Z0-9_-]{5,64}$/.test(id)||!Number.isSafeInteger(revision)||revision<0||!Number.isSafeInteger(mid)||mid<1||!IMG.test(image)||!caption||caption.length>2200)throw Error("INVALID_INPUT");
  return {key:source+":"+id,source,id,revision,mid,image,caption};
}
class MetaRequestError extends Error {
  constructor(response,body){
    super("META_REQUEST_FAILED");
    const e=body&&typeof body.error==="object"?body.error:{};
    this.httpStatus=Number(response.status)||0;
    this.metaCode=Number.isSafeInteger(Number(e.code))?Number(e.code):null;
    this.metaSubcode=Number.isSafeInteger(Number(e.error_subcode))?Number(e.error_subcode):null;
    this.metaTransient=e.is_transient===true;
    this.metaType=typeof e.type==="string"&&/^[A-Za-z]{1,60}$/.test(e.type)?e.type:null;
  }
}
function safeMetaDiagnostic(err){
  if(!(err instanceof MetaRequestError))return {};
  return {meta_http_status:err.httpStatus,meta_error_code:err.metaCode,
    meta_error_subcode:err.metaSubcode,meta_error_type:err.metaType,
    meta_is_transient:err.metaTransient};
}
async function meta(env,endpoint,params={},verb="POST"){
  if(!env.INSTAGRAM_PAGE_ACCESS_TOKEN)throw Error("MISSING_TOKEN");
  const data=new URLSearchParams(params);
  const url="https://graph.facebook.com/v26.0/"+endpoint+(verb==="GET"?"?"+data:"");
  const result=await fetch(url,{method:verb,headers:{"content-type":"application/x-www-form-urlencoded","authorization":"Bearer "+env.INSTAGRAM_PAGE_ACCESS_TOKEN},...(verb==="POST"?{body:data}:{})});
  const json=await result.json().catch(()=>({}));
  if(!result.ok||json.error)throw new MetaRequestError(result,json);
  return json;
}
// Read-only account and schema preflight. Never posts to Meta, mutates D1, or returns a token.
// A Page token MUST identify the expected Facebook Page; a user token is not accepted.
async function metaPreflight(env){
  const pageId="1424696600717440",igId=String(env.INSTAGRAM_USER_ID||"");
  if(!env.IG_DB||!env.INSTAGRAM_PAGE_ACCESS_TOKEN||igId!=="17841414511690117"){
    return answer({ok:false,error:"MISSING_REQUIRED_BINDINGS",active:isActive(env)},503);
  }
  let schemaReady=false;
  try{
    const table=await env.IG_DB.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='instagram_posts'").first();
    schemaReady=table?.name==="instagram_posts";
  }catch(_err){}
  let me,page;
  try{
    me=await meta(env,"me",{fields:"id,name"},"GET");
  }catch(err){
    return answer({ok:false,error:"META_TOKEN_INVALID_OR_INSUFFICIENT_PERMISSIONS",
      meta_check:"page_token_identity",...safeMetaDiagnostic(err),
      schema_ready:schemaReady,active:isActive(env)},502);
  }
  try{
    page=await meta(env,pageId,{fields:"id,name,instagram_business_account{id,username}"},"GET");
  }catch(err){
    return answer({ok:false,error:"META_TOKEN_INVALID_OR_INSUFFICIENT_PERMISSIONS",
      meta_check:"page_instagram_link",...safeMetaDiagnostic(err),
      schema_ready:schemaReady,active:isActive(env)},502);
  }
  const pageMatches=String(me?.id||"")===pageId&&String(page?.id||"")===pageId;
  const linked=page?.instagram_business_account||{};
  const instagramMatches=String(linked.id||"")===igId;
  const instagramUsernameMatches=String(linked.username||"").toLowerCase()==="ttactualidad";
  const ok=pageMatches&&instagramMatches&&instagramUsernameMatches&&schemaReady;
  return answer({
    ok,read_only:true,active:isActive(env),
    page_token_matches_expected_page:pageMatches,
    instagram_account_linked:instagramMatches,
    instagram_username_matches:instagramUsernameMatches,
    schema_ready:schemaReady
  },ok?200:422);
}
async function state(db,key){return db.prepare("SELECT * FROM instagram_posts WHERE id=?").bind(key).first();}
async function readPublicationStatus(req,env){
  const url=new URL(req.url);
  const source=String(url.searchParams.get("source")||"");
  const eventId=String(url.searchParams.get("event_id")||"");
  if(!["ttittulares","ttendencias"].includes(source)||!/^[A-Za-z0-9_-]{5,64}$/.test(eventId)){
    return answer({ok:false,error:"INVALID_IDENTITY"},400);
  }
  if(!env.IG_DB)return answer({ok:false,error:"D1_NOT_CONFIGURED"},503);
  const row=await state(env.IG_DB,source+":"+eventId);
  if(!row)return answer({ok:true,source,event_id:eventId,state:"not_recorded",found:false});
  // Strictly read-only: never create, retry or reconcile publication here.
  return answer({ok:true,source,event_id:eventId,found:true,
    state:row.state,media_id:row.media_id||null,permalink:row.permalink||null,
    container_id:row.container_id||null,updated_at:row.updated_at||null});
}

async function change(db,key,old,now,fields={}){
  const keys=Object.keys(fields);
  const sql="UPDATE instagram_posts SET state=?,updated_at=CURRENT_TIMESTAMP"+keys.map(k=>","+k+"=?").join("")+" WHERE id=? AND state=?";
  const r=await db.prepare(sql).bind(now,...keys.map(k=>fields[k]),key,old).run();
  return r.meta?.changes===1;
}
async function publish(env,item){
  const db=env.IG_DB,ig=String(env.INSTAGRAM_USER_ID||"");
  if(!db||!/^\d{10,25}$/.test(ig)||!env.INSTAGRAM_PAGE_ACCESS_TOKEN)return answer({ok:false,error:"NOT_CONFIGURED"},503);
  await db.prepare("INSERT OR IGNORE INTO instagram_posts(id,source,event_id,revision,telegram_message_id,image_url,caption,state) VALUES(?,?,?,?,?,?,?,'reserved')")
    .bind(item.key,item.source,item.id,item.revision,item.mid,item.image,item.caption).run();
  let row=await state(db,item.key);
  if(!row)return answer({ok:false,error:"STORAGE_FAILURE"},503);
  if(row.image_url!==item.image||row.caption!==item.caption||Number(row.telegram_message_id)!==item.mid)return answer({ok:false,error:"SELECTION_CHANGED"},409);
  if(row.state==="published"){
    // Meta occasionally delays permalink availability. Querying the already
    // published media ID is read-only and can never publish a second post.
    if(!row.permalink&&/^\d+$/.test(String(row.media_id||""))){
      try{
        const url=(await meta(env,String(row.media_id),{fields:"permalink"},"GET")).permalink||null;
        if(url){
          await db.prepare("UPDATE instagram_posts SET permalink=? WHERE id=? AND state='published'").bind(url,item.key).run();
          row={...row,permalink:url};
        }
      }catch(_error){}
    }
    return answer({ok:true,state:"published",duplicate:true,media_id:row.media_id,permalink:row.permalink});
  }
  if(["publishing","uncertain","creating"].includes(row.state))return answer({ok:false,error:"NEEDS_RECONCILIATION",state:row.state},409);
  if(row.state==="failed_before_publish"){
    if(!await change(db,item.key,"failed_before_publish","reserved"))return answer({ok:false,error:"BUSY"},409);
    row=await state(db,item.key);
  }
  if(row.state==="reserved"){
    if(!await change(db,item.key,"reserved","creating"))return answer({ok:false,error:"BUSY"},409);
    try{
      const creation=await meta(env,ig+"/media",{image_url:item.image,caption:instagramCaption(item.caption)});
      if(!/^\d+$/.test(String(creation.id||"")))throw Error("BAD_CONTAINER");
      await change(db,item.key,"creating","container_created",{container_id:String(creation.id)});
      row=await state(db,item.key);
    }catch(err){
      await change(db,item.key,"creating","failed_before_publish");
      // Codes only, never Meta raw messages/tokens. The authenticated caller
      // needs this distinction: missing permission vs inaccessible image.
      return answer({ok:false,error:"CONTAINER_CREATION_FAILED",
        ...safeMetaDiagnostic(err)},502);
    }
  }
  if(row.state!=="container_created")return answer({ok:false,error:"NEEDS_RECONCILIATION"},409);
  let status;
  try{status=(await meta(env,row.container_id,{fields:"status_code"},"GET")).status_code;}
  catch(_err){return answer({ok:false,error:"STATUS_CHECK_FAILED"},502);}
  if(status==="IN_PROGRESS")return answer({ok:true,state:"processing",retry_after_seconds:15},202);
  if(status!=="FINISHED")return answer({ok:false,error:"CONTAINER_NOT_READY",status_code:status},422);
  if(!await change(db,item.key,"container_created","publishing"))return answer({ok:false,error:"BUSY"},409);
  try{
    const post=await meta(env,ig+"/media_publish",{creation_id:row.container_id});
    if(!/^\d+$/.test(String(post.id||"")))throw Error("NO_PUBLICATION_ID");
    if(!await change(db,item.key,"publishing","published",{media_id:String(post.id)}))throw Error("STORAGE_FAILURE");
    let permalink=null;
    try{
      permalink=(await meta(env,String(post.id),{fields:"permalink"},"GET")).permalink||null;
      if(permalink)await db.prepare("UPDATE instagram_posts SET permalink=? WHERE id=? AND state='published'").bind(permalink,item.key).run();
    }catch(_err){}
    return answer({ok:true,state:"published",media_id:String(post.id),permalink});
  }catch(_err){
    // A timeout may happen AFTER Meta published; NEVER silently retry.
    await change(db,item.key,"publishing","uncertain");
    return answer({ok:false,state:"uncertain",error:"CHECK_INSTAGRAM_MANUALLY"},503);
  }
}
export default {async fetch(req,env){
  const pathname=new URL(req.url).pathname;
  if(pathname==="/health"&&req.method==="GET")return answer({ok:true,service:"tt-actualidad-instagram",active:isActive(env)});
  if(pathname==="/publication-status"&&req.method==="GET"){
    if(!authorize(req,env))return answer({ok:false,error:"UNAUTHORIZED"},401);
    try{return await readPublicationStatus(req,env)}
    catch(_error){return answer({ok:false,error:"STATUS_QUERY_FAILED"},503)}
  }
  if(pathname==="/meta-preflight"&&req.method==="GET"){
    if(!authorize(req,env))return answer({ok:false,error:"UNAUTHORIZED"},401);
    return metaPreflight(env);
  }
  if(pathname!=="/publish"||req.method!=="POST")return answer({ok:false,error:"NOT_FOUND"},404);
  if(!authorize(req,env))return answer({ok:false,error:"UNAUTHORIZED"},401);
  if(!isActive(env))return answer({ok:false,error:"PILOT_DISABLED"},503);
  let item;
  try{item=inputCheck(await req.json());}catch(_err){return answer({ok:false,error:"INVALID_REQUEST"},400);}
  try{return await publish(env,item);}catch(_err){return answer({ok:false,error:"INTERNAL_ERROR"},503);}
}};
export {authorize,inputCheck,instagramCaption};
