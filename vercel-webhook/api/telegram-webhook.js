const REPO = process.env.GITHUB_REPO || "fabricelop/europapress-rss";
const BRANCH = process.env.GITHUB_BRANCH || "main";
const NEWS_QUEUE = "telegram/requests.json";
const TRENDS_QUEUE = "trends/requests.json";
const SR_QUEUE = "selorecordamos/requests.json";
const EMERGENCY_QUEUE = "telegram/emergency-requests.json";

function b64decode(s) { return Buffer.from((s || "").replace(/\n/g, ""), "base64").toString("utf8"); }
function b64encode(s) { return Buffer.from(s, "utf8").toString("base64"); }

async function telegram(method, payload = {}) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload),
  });
  const data = await r.json();
  if (!data.ok) throw new Error(`Telegram ${method}: ${JSON.stringify(data)}`);
  return data.result;
}

async function gh(path, options = {}) {
  const token = process.env.GITHUB_TOKEN;
  return fetch(`https://api.github.com/repos/${REPO}/${path}`, {
    ...options,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": "2022-11-28",
      "user-agent": "ttittulares-telegram-webhook",
      ...(options.headers || {}),
    },
  });
}

async function dispatchWorkflow(workflowFile) {
  const r = await gh(`actions/workflows/${encodeURIComponent(workflowFile)}/dispatches`, {
    method: "POST",
    headers: {"content-type":"application/json"},
    body: JSON.stringify({ref: BRANCH}),
  });
  if (!r.ok) throw new Error(`GitHub workflow dispatch ${workflowFile}: ${r.status} ${await r.text()}`);
  return true;
}


async function mutateJsonFile(path, message, mutator) {
  for (let attempt = 1; attempt <= 6; attempt++) {
    const get = await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
    if (!get.ok) throw new Error(`GitHub GET ${path}: ${get.status} ${await get.text()}`);
    const file = await get.json();
    let encoded=String(file.content||"").replace(/\n/g,"");
    if(!encoded&&file.sha){
      const blob=await gh(`git/blobs/${encodeURIComponent(file.sha)}`);
      if(!blob.ok) throw new Error(`GitHub blob GET ${path}: ${blob.status} ${await blob.text()}`);
      const bj=await blob.json();
      encoded=String(bj.content||"").replace(/\n/g,"");
    }
    const doc = JSON.parse(b64decode(encoded) || "{}");
    const out = (await mutator(doc)) || doc;
    const put = await gh(`contents/${path}`, {
      method: "PUT",
      headers: {"content-type":"application/json"},
      body: JSON.stringify({
        message,
        content: b64encode(JSON.stringify(out, null, 2) + "\n"),
        sha: file.sha,
        branch: BRANCH,
      }),
    });
    if (put.ok) return out;
    if (![409, 422].includes(put.status)) throw new Error(`GitHub PUT ${path}: ${put.status} ${await put.text()}`);
    await new Promise(r => setTimeout(r, attempt * 180));
  }
  throw new Error(`Conflicto persistente actualizando ${path}`);
}

async function closeTtiFromTelegram(eventId, status, messageId) {
  const id = String(eventId || "").trim();
  if (!id) throw new Error("event_id ausente");
  const now = new Date().toISOString();
  const terminal = status === "published" ? "PUBLISHED" : "DISMISSED";

  await mutateJsonFile(
    "ttittulares/decisions.json",
    (status === "published" ? "Publicar" : "Desestimar") + " TTiTTulares desde Telegram",
    (doc) => {
      doc.project ||= "TTiTTulares";
      doc.items = Array.isArray(doc.items) ? doc.items : [];
      let row = doc.items.find(x => String(x.event_id || "") === id);
      if (!row) { row = {event_id:id}; doc.items.push(row); }
      Object.assign(row, {
        status,
        updated_at: now,
        decision_source: "telegram",
        telegram_message_id: Number(messageId || 0),
      });
      doc.updated_at = now;
      return doc;
    }
  );

  await Promise.allSettled([
    mutateJsonFile("ttittulares/prepared.json", "Retirar noticia cerrada desde Telegram", (doc) => {
      doc.items = (Array.isArray(doc.items) ? doc.items : []).filter(x => String(x.event_id || "") !== id);
      doc.updated_at = now;
      return doc;
    }),
    mutateJsonFile("telegram/editorial-processing.json", "Cerrar noticia TTiTTulares desde Telegram", (doc) => {
      doc.items = Array.isArray(doc.items) ? doc.items : [];
      for (const row of doc.items) {
        if (String(row.event_id || row.id || "") === id) {
          row.status = terminal;
          row[status === "published" ? "published_at" : "dismissed_at"] = now;
          row.decision_source = "telegram";
          row.telegram_message_id = Number(messageId || 0);
        }
      }
      doc.updated_at = now;
      return doc;
    }),
    mutateJsonFile("telegram/events.json", "Cerrar evento TTiTTulares desde Telegram", (doc) => {
      doc.events = Array.isArray(doc.events) ? doc.events : [];
      for (const row of doc.events) {
        if (String(row.id || row.event_id || "") === id) {
          row.status = terminal;
          row[status === "published" ? "published_at" : "dismissed_at"] = now;
          row.decision_source = "telegram";
        }
      }
      doc.updated_at = now;
      return doc;
    }),
  ]);

  try {
    await mutateJsonFile("ttittulares/manual-submissions.json", "Actualizar archivo manual desde Telegram", (doc) => {
      doc.items = Array.isArray(doc.items) ? doc.items : [];
      for (const row of doc.items) {
        if (String(row.event_id || "") === id) {
          row.status = terminal;
          row.updated_at = now;
          row.decision_source = "telegram";
        }
      }
      doc.updated_at = now;
      return doc;
    });
  } catch (e) {
    console.error("manual-submissions cierre opcional", e);
  }

  return {ok:true,event_id:id,status};
}



async function requestTtiImageRetry(eventId,currentMessageId,chatId){
  const id=String(eventId||"").trim();
  if(!id)throw new Error("event_id ausente");
  const now=new Date().toISOString();
  let found=false;
  await mutateJsonFile("ttittulares/prepared.json","Reenviar TTiTTulares a Listas para nueva IA",(doc)=>{
    doc.items=Array.isArray(doc.items)?doc.items:[];
    for(const item of doc.items){
      if(String(item.event_id||"")!==id)continue;
      found=true;
      item.ai_image_regenerate_requested=true;
      item.ai_image_regenerate_requested_at=now;
      item.ai_image_regenerate_request_version=Number(item.ai_image_regenerate_request_version||0)+1;
      item.telegram_timeout_retry_at=now;
      item.image_pending=true;
    }
    doc.updated_at=now;
    return doc;
  });
  if(!found)throw new Error("La noticia ya no está en Listas");

  const mids=[];
  await mutateJsonFile("telegram/ttittulares-deliveries.json","Reintentar IA TTiTTulares desde Telegram",(doc)=>{
    let changed=false;
    for(const row of doc.items||[]){
      if(String(row.event_id||"")!==id||!row.timeout_fallback||String(row.status||"").toLowerCase()!=="sent")continue;
      row.status="retry_requested";
      row.retry_requested_at=now;
      row.decision_source="telegram_retry";
      changed=true;
      for(const k of ["telegram_message_id","archive_telegram_message_id"]){
        const mid=Number(row[k]||0); if(mid&&!mids.includes(mid))mids.push(mid);
      }
    }
    if(changed)doc.updated_at=now;
    return doc;
  });
  const current=Number(currentMessageId||0); if(current&&!mids.includes(current))mids.push(current);

  // El borrado directo puede fallar de forma transitoria. Registramos SIEMPRE
  // los mensajes en la cola fiable de limpieza; el workflow los borra con el
  // mismo bot y deja trazabilidad de éxito/error.
  if(mids.length){
    await mutateJsonFile("telegram/delete-message-queue.json","Encolar limpieza tras reenviar a Listas",(doc)=>{
      doc.items=Array.isArray(doc.items)?doc.items:[];
      const known=new Set(doc.items.filter(x=>String(x.status||"")==="pending").map(x=>Number(x.message_id||0)));
      for(const mid of mids){
        if(known.has(mid))continue;
        doc.items.push({
          message_id:mid,
          event_id:id,
          reason:"retry_to_listas",
          status:"pending",
          queued_at:now
        });
        known.add(mid);
      }
      doc.updated_at=now;
      return doc;
    });
  }

  await dispatchWorkflow("repair-ttittulares-listas.yml");
  let directDeleted=0;
  for(const mid of mids){
    const out=await safeTelegram("deleteMessage",{chat_id:chatId,message_id:mid});
    if(out!==null)directDeleted++;
  }
  return {ok:true,event_id:id,retry:true,delete_requested:mids.length,direct_deleted:directDeleted};
}

async function requestTrendImageRetry(trendId,revision,currentMessageId,chatId){
  const id=String(trendId||"").trim(),rev=Number(revision||0);
  if(!id)throw new Error("trend_id ausente");
  const now=new Date().toISOString();
  let found=false;
  await mutateJsonFile("trends/telegram-manual-explained.json","Reenviar TTendencias a Listas para nueva IA",(doc)=>{
    doc.items=Array.isArray(doc.items)?doc.items:[];
    for(const row of doc.items){
      if(String(row.id||"")!==id||Number(row.revision||0)!==rev)continue;
      found=true;
      row.ai_image_regenerate_requested=true;
      row.ai_image_regenerate_requested_at=now;
      row.ai_image_regenerate_request_version=Number(row.ai_image_regenerate_request_version||0)+1;
      row.telegram_timeout_retry_at=now;
      row.image_pending=true;
    }
    doc.updated_at=now;
    return doc;
  });
  if(!found)throw new Error("La tendencia ya no está en Listas");

  const mids=[];
  await mutateJsonFile("trends/telegram-image-deliveries.json","Reintentar IA TTendencias desde Telegram",(doc)=>{
    let changed=false;
    for(const row of doc.items||[]){
      if(String(row.event_id||"")!==id||Number(row.revision||0)!==rev||!row.timeout_fallback||String(row.status||"").toLowerCase()!=="sent")continue;
      row.status="retry_requested";
      row.retry_requested_at=now;
      row.decision_source="telegram_retry";
      changed=true;
      for(const k of ["telegram_message_id","archive_telegram_message_id"]){
        const mid=Number(row[k]||0); if(mid&&!mids.includes(mid))mids.push(mid);
      }
    }
    if(changed)doc.updated_at=now;
    return doc;
  });
  const current=Number(currentMessageId||0); if(current&&!mids.includes(current))mids.push(current);
  await dispatchWorkflow("repair-ttendencias-explicadas.yml");
  for(const mid of mids)await safeTelegram("deleteMessage",{chat_id:chatId,message_id:mid});
  return {ok:true,event_id:id,revision:rev,retry:true,deleted:mids.length};
}

async function upsertEditorialProcessing(eventId, title, url) {
  const path = "telegram/editorial-processing.json";
  for (let attempt = 1; attempt <= 5; attempt++) {
    const get = await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
    if (!get.ok) throw new Error(`GitHub GET editorial-processing: ${get.status} ${await get.text()}`);
    const file = await get.json();
    const doc = JSON.parse(b64decode(file.content) || '{"items":[]}');
    doc.items ||= [];
    const now = new Date().toISOString();
    const existing = doc.items.find(x => String(x.event_id || "") === String(eventId));
    if (existing) {
      existing.status = "PROCESSING";
      if (title) existing.title = title;
      if (url) existing.url = url;
      existing.selected_at ||= now;
    } else {
      doc.items.push({event_id:String(eventId),title:title||("Radar "+eventId),url:url||"",sources:[],source_count:0,selected_at:now,status:"PROCESSING"});
    }
    const put = await gh(`contents/${path}`, {
      method:"PUT",
      headers:{"content-type":"application/json"},
      body:JSON.stringify({message:"Seleccionar noticia desde Telegram",content:b64encode(JSON.stringify(doc,null,2)+"\n"),sha:file.sha,branch:BRANCH}),
    });
    if (put.ok) return true;
    if (![409,422].includes(put.status)) throw new Error(`GitHub PUT editorial-processing: ${put.status} ${await put.text()}`);
    await new Promise(r=>setTimeout(r,attempt*150));
  }
  throw new Error("No se pudo actualizar editorial-processing tras varios reintentos");
}

async function appendRequest(request, queuePath = NEWS_QUEUE) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    const get = await gh(`contents/${queuePath}?ref=${encodeURIComponent(BRANCH)}`);
    if (!get.ok) throw new Error(`GitHub GET queue ${queuePath}: ${get.status} ${await get.text()}`);
    const file = await get.json();
    const queue = JSON.parse(b64decode(file.content) || '{"requests":[]}');
    queue.requests ||= [];
    if (queue.requests.some((r) => r.update_id === request.update_id)) return false;
    if (request.dedupe_text && queue.requests.some((r) => r.type === request.type && r.text === request.text)) return false;
    const stored = { ...request };
    delete stored.dedupe_text;
    queue.requests.push(stored);
    queue.requests = queue.requests.slice(-100);
    const put = await gh(`contents/${queuePath}`, {
      method: "PUT", headers: { "content-type": "application/json" },
      body: JSON.stringify({
        message: queuePath === TRENDS_QUEUE
          ? "Procesar orden TTendencias por webhook"
          : queuePath === SR_QUEUE
            ? "Procesar orden SeLoRecordamos por webhook"
            : "Procesar orden de Telegram por webhook",
        content: b64encode(JSON.stringify(queue) + "\n"), sha: file.sha, branch: BRANCH,
      }),
    });
    if (put.ok) return true;
    if (![409, 422].includes(put.status)) throw new Error(`GitHub PUT queue: ${put.status} ${await put.text()}`);
    await new Promise((resolve) => setTimeout(resolve, attempt * 150));
  }
  throw new Error("No se pudo guardar la orden de Telegram tras varios reintentos");
}

async function fetchCandidate(id) {
  if (!/^\d+$/.test(String(id || ""))) return null;
  const get = await gh(`contents/selorecordamos/candidates/${id}.json?ref=${encodeURIComponent(BRANCH)}`);
  if (!get.ok) return null;
  const file = await get.json();
  return JSON.parse(b64decode(file.content));
}

async function ttiDeliveryMessageIds(eventId) {
  const id=String(eventId||"").trim();
  if(!id)return [];
  try{
    const get=await gh(`contents/telegram/ttittulares-deliveries.json?ref=${encodeURIComponent(BRANCH)}&t=${Date.now()}`,{cache:"no-store",headers:{"cache-control":"no-cache"}});
    if(!get.ok)return [];
    const file=await get.json();
    const doc=JSON.parse(b64decode(file.content)||'{"items":[]}');
    const mids=[];
    for(const row of [...(doc.items||[])].reverse()){
      if(String(row.event_id||"")!==id)continue;
      for(const k of ["telegram_message_id","archive_telegram_message_id"]){
        const mid=Number(row[k]||0);
        if(Number.isInteger(mid)&&mid>0&&!mids.includes(mid))mids.push(mid);
      }
      if(mids.length)break;
    }
    return mids;
  }catch(e){
    console.error("TTiTTulares delivery lookup",e);
    return [];
  }
}

async function deleteTtiPackageNow(eventId,currentMessageId,chatId){
  const mids=await ttiDeliveryMessageIds(eventId);
  const current=Number(currentMessageId||0);
  if(current>0&&!mids.includes(current))mids.push(current);
  let deleted=0;
  for(const mid of mids){
    const out=await safeTelegram("deleteMessage",{chat_id:chatId,message_id:mid});
    if(out!==null)deleted++;
  }
  return {requested:mids.length,deleted};
}

async function safeTelegram(method, payload) {
  try { return await telegram(method, payload); }
  catch (e) { console.error(e); return null; }
}

function requestObj(update, type, text, dedupe_text = false) {
  return { update_id: update.update_id, created_at: new Date().toISOString(), type, text, dedupe_text };
}

function isTrendMessage(text) {
  return /\bTTENDENCIA\b/i.test(text || "") || /^[🔵🟢🟣🟠🔴🟡🟤⚪]\s*T\d+\b/u.test(text || "");
}

function extractPreparedHeadline(original, data) {
  const requestedId = String(data || "").split(":", 2)[1] || "";
  if (requestedId) {
    const escaped = requestedId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const exact = original.match(new RegExp(`^${escaped}\\.\\s*(.+)$`, "m"));
    if (exact) return exact[1].trim();
  }
  const fallback = original.match(/^N\d+\.\s*(.+)$/m);
  return (fallback ? fallback[1] : original).trim();
}

async function telegramWebhookAdmin(req,res){
  const expected=process.env.TELEGRAM_WEBHOOK_SECRET;
  const supplied=req.headers["x-tt-admin-secret"];
  if(!expected||supplied!==expected)return res.status(401).json({ok:false});
  const token=process.env.TELEGRAM_BOT_TOKEN;
  if(!token)return res.status(500).json({ok:false,error:"TELEGRAM_BOT_TOKEN missing"});
  const base=`https://api.telegram.org/bot${token}`;
  if(req.method==="GET"){
    const r=await fetch(base+"/getWebhookInfo");
    const data=await r.json();
    if(data?.result?.url){try{data.result.url=new URL(data.result.url).origin+new URL(data.result.url).pathname}catch{}}
    return res.status(r.ok?200:502).json(data)
  }
  if(req.method==="POST"){
    const host=req.headers["x-forwarded-host"]||req.headers.host;
    const proto=req.headers["x-forwarded-proto"]||"https";
    const url=`${proto}://${host}/api/telegram-webhook`;
    const r=await fetch(base+"/setWebhook",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({url,secret_token:expected,allowed_updates:["message","callback_query"],drop_pending_updates:false})});
    const data=await r.json();
    return res.status(r.ok?200:502).json({...data,webhook_url:url})
  }
  return res.status(405).json({ok:false})
}

export default async function handler(req, res) {
  if(String(req.query?.admin||"")==="1") return telegramWebhookAdmin(req,res);
  if (req.method === "GET") return res.status(200).json({ ok: true, service: "ttittulares-telegram-webhook" });
  if (req.method !== "POST") return res.status(405).json({ ok: false });
  const expected = process.env.TELEGRAM_WEBHOOK_SECRET;
  const received = req.headers["x-telegram-bot-api-secret-token"];
  if (expected && received && received !== expected) return res.status(401).json({ ok: false });
  const update = req.body || {};
  const allowedChat = String(process.env.TELEGRAM_CHAT_ID || "");

  try {
    if (update.callback_query) {
      const cq = update.callback_query;
      const msg = cq.message || {};
      const chatId = String((msg.chat || {}).id || "");
      if (chatId !== allowedChat) return res.status(200).json({ ok: true });
      const data = cq.data || "";

      if (data.startsWith("tx:")) {
        const parts = data.split(":");
        const action = parts[1] || "";
        const id = parts[2] || "";
        const revision = Number(parts[3] || 0);
        if (action==="r" && id) {
          try{
            await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"🔄 Reenviada a Listas. Nuevo intento de IA."});
            const out=await requestTrendImageRetry(id,revision,msg.message_id,allowedChat);
            return res.status(200).json(out);
          }catch(e){
            console.error("TTendencias retry callback failed",{id,revision,error:String(e?.message||e)});
            await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"No se pudo reenviar a Listas.",show_alert:true});
            return res.status(200).json({ok:false,retry:false,event_id:id,revision});
          }
        }
        if (!["p", "d"].includes(action) || !id) {
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "Acción no válida." });
          return res.status(200).json({ ok: true, ignored: true });
        }
        const status = action === "p" ? "published" : "dismissed";
        await safeTelegram("answerCallbackQuery", {
          callback_query_id: cq.id,
          text: status === "published" ? "Guardando publicación…" : "Guardando descarte…"
        });
        const now = new Date().toISOString();
        const mids = [];
        let matched = false;

        async function mutateTrendJson(path, mutate) {
          for (let attempt = 1; attempt <= 5; attempt++) {
            const get = await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
            if (!get.ok) throw new Error(`GitHub GET ${path}: ${get.status} ${await get.text()}`);
            const file = await get.json();
            const doc = JSON.parse(b64decode(file.content) || "{}");
            const changed = mutate(doc);
            if (!changed) return false;
            const put = await gh(`contents/${path}`, {
              method: "PUT",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ message: `Cerrar paquete TTendencias desde Telegram (${status})`, content: b64encode(JSON.stringify(doc, null, 2) + "\n"), sha: file.sha, branch: BRANCH }),
            });
            if (put.ok) return true;
            if (![409, 422].includes(put.status)) throw new Error(`GitHub PUT ${path}: ${put.status} ${await put.text()}`);
            await new Promise(resolve => setTimeout(resolve, attempt * 180));
          }
          throw new Error(`No se pudo actualizar ${path} tras varios reintentos`);
        }

        try {
          // La entrega es la fuente autoritativa del cierre del paquete Telegram.
          // Basta una escritura para cerrar visualmente TTendencias; la tarjeta
          // explicada se reconcilia desde este ledger en ttendencias-control.
          let deliveryMatched = false;
          await mutateTrendJson("trends/telegram-image-deliveries.json", (doc) => {
            let changed = false;
            for (const row of (doc.items || [])) {
              if (String(row.event_id || "") !== id || Number(row.revision || 0) !== revision) continue;
              matched = true; deliveryMatched = true; changed = true;
              row.status = status;
              row.decision_source = "telegram_webhook";
              row[status === "published" ? "published_at" : "dismissed_at"] = now;
              for (const k of ["telegram_message_id", "archive_telegram_message_id"]) {
                const mid = Number(row[k] || 0);
                if (mid && !mids.includes(mid)) mids.push(mid);
              }
            }
            if (changed) doc.updated_at = now;
            return changed;
          });

          const currentMid = Number(msg.message_id || 0);
          if (currentMid && !mids.includes(currentMid)) mids.push(currentMid);

          if (!deliveryMatched) {
            await safeTelegram("sendMessage", { chat_id: allowedChat, text: "⚠️ No encuentro el paquete vigente de TTendencias." });
            return res.status(200).json({ ok: false, matched: false });
          }

          // En cuanto el ledger autoritativo queda cerrado, retirar el paquete
          // de Telegram sin esperar una segunda escritura GitHub.
          for (const mid of mids) await safeTelegram("deleteMessage", { chat_id: allowedChat, message_id: mid });

          // Sincronización secundaria: útil para inspección humana, pero nunca
          // debe bloquear el cierre ni hacer que el botón parezca no responder.
          try {
            await mutateTrendJson("trends/telegram-manual-explained.json", (doc) => {
              let changed = false;
              for (const row of (doc.items || [])) {
                if (String(row.id || "") !== id || Number(row.revision || 0) !== revision) continue;
                changed = true;
                row.telegram_package_status = status;
                row.telegram_package_updated_at = now;
                row.telegram_decision_source = "telegram_webhook";
                row[status === "published" ? "telegram_published_at" : "telegram_dismissed_at"] = now;
              }
              if (changed) doc.updated_at = now;
              return changed;
            });
          } catch (syncError) {
            console.error("TTendencias secondary explained sync failed", {
              id, revision, status, error: String(syncError?.message || syncError)
            });
          }

          return res.status(200).json({ ok: true, status, event_id: id, revision, deleted: mids.length });
        } catch (e) {
          const raw = String(e?.message || e);
          console.error("TTendencias callback persistence failed", { id, revision, status, error: raw });
          const rateLimited = /rate limit|403/i.test(raw);
          await safeTelegram("sendMessage", {
            chat_id: allowedChat,
            text: rateLimited
              ? "⚠️ GitHub está temporalmente limitado. No he borrado el paquete; vuelve a pulsar Publicado dentro de unos minutos."
              : "⚠️ No se pudo guardar el estado de TTendencias; el mensaje se conserva."
          });
          return res.status(200).json({ ok: false, status, event_id: id, revision, rate_limited: rateLimited });
        }
      } else if (data.startsWith("tt:")) {
        const parts = data.split(":");
        const action = parts[1] || "";
        const id = parts.slice(2).join(":");
        if(action==="r" && id){
          try{
            await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"🔄 Reenviada a Listas. Nuevo intento de IA."});
            const out=await requestTtiImageRetry(id,msg.message_id,allowedChat);
            return res.status(200).json(out);
          }catch(e){
            console.error("TTiTTulares retry callback failed",{event_id:id,error:String(e?.message||e)});
            await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"No se pudo reenviar a Listas.",show_alert:true});
            return res.status(200).json({ok:false,retry:false,event_id:id});
          }
        }
        if (!["p","d"].includes(action) || !id) {
          await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"Acción no válida.",show_alert:true});
          return res.status(200).json({ok:true,stored:false});
        }
        try {
          const status = action === "p" ? "published" : "dismissed";
          await closeTtiFromTelegram(id,status,Number(msg.message_id || 0));
          await safeTelegram("answerCallbackQuery",{
            callback_query_id:cq.id,
            text:status === "published" ? "✅ Publicado." : "🗑 Desestimado."
          });
          const telegram_delete=await deleteTtiPackageNow(id,msg.message_id,allowedChat);
          return res.status(200).json({ok:true,stored:true,event_id:id,status,telegram_delete});
        } catch (e) {
          console.error("TTiTTulares queue from Telegram", e);
          await safeTelegram("answerCallbackQuery",{
            callback_query_id:cq.id,
            text:"No se pudo guardar el estado. El mensaje se conserva.",
            show_alert:true
          });
          return res.status(200).json({ok:true,stored:false,event_id:id,error:String(e)});
        }
      } else if (data.startsWith("emergency:")) {
        const parts=data.split(":"); const action=parts[1]||""; const id=parts.slice(2).join(":")||"";
        if(action==="prepare"){
          const original=msg.text||"";
          const headline=extractPreparedHeadline(original,data);
          let url="";
          for (const row of (msg.reply_markup?.inline_keyboard||[])) {
            for (const b of (row||[])) { if (b?.url && !url) url=String(b.url); }
          }
          await upsertEditorialProcessing(id,headline,url);
          await appendRequest(requestObj(update,"emergency_action",action+"|"+id),EMERGENCY_QUEUE);
          await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"Enviada a Elaborando."});
          await safeTelegram("deleteMessage",{chat_id:allowedChat,message_id:msg.message_id});
          return res.status(200).json({ok:true,queued:true});
        }
        const stored=await appendRequest(requestObj(update,"emergency_action",action+"|"+id),EMERGENCY_QUEUE);
        await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:action==="ttd"||action==="dismiss"?"Desestimada.":"Marcada como publicada."});
        let telegram_delete={requested:0,deleted:0};
        if(action==="ttp"||action==="ttd"||action==="dismiss"){
          telegram_delete=await deleteTtiPackageNow(id,msg.message_id,allowedChat);
        }
        return res.status(200).json({ok:true,stored,telegram_delete});
      } else if (data.startsWith("media:")) {
        const parts=data.split(":"); const action=parts[1]||""; const id=parts[2]||"";
        if (!/^(PREPARE|INTERESTING|DISMISS)$/.test(action) || !/^\d+$/.test(id)) {
          await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"Acción no válida."});
        } else {
          const actionUrl="https://tt-control.fabricelop.workers.dev/api/media-alert/action";
          const r=await fetch(actionUrl,{method:"POST",headers:{"content-type":"application/json","authorization":"Bearer "+process.env.TT_CONTROL_BRIDGE_TOKEN},body:JSON.stringify({id:Number(id),action})});
          if (r.ok) {
            await telegram("answerCallbackQuery",{callback_query_id:cq.id,text:action==="PREPARE"?"Enviada a Elaborando.":action==="INTERESTING"?"Marcada como interesante.":"Descartada."});
            if(action==="PREPARE"){
              const dispatch=await fetch("https://api.github.com/repos/fabricelop/tt-control/actions/workflows/tt-control-bridge.yml/dispatches",{method:"POST",headers:{accept:"application/vnd.github+json",authorization:"Bearer "+process.env.GITHUB_TOKEN,"x-github-api-version":"2022-11-28","user-agent":"tt-control-telegram-webhook"},body:JSON.stringify({ref:"main"})});
              if(!dispatch.ok) console.error("TT Control immediate dispatch failed",dispatch.status,await dispatch.text());
            }
            await telegram("deleteMessage",{chat_id:allowedChat,message_id:msg.message_id});
          } else { console.error("TT Control media action failed",r.status,await r.text()); await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:"No se pudo aplicar la acción."}); }
        }
      } else if (data.startsWith("sr:evaluate:")) {
        const tweetId = data.split(":")[2] || "";
        const candidate = await fetchCandidate(tweetId);
        if (!candidate) {
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "No encuentro este candidato." });
        } else {
          const requestText = [
            "Evalúa este candidato de SeLoRecordamos y propón respuestas fieles al estilo histórico de la cuenta.",
            `Tweet ID: ${candidate.id}`,
            `Usuario: ${candidate.user}`,
            `Texto: ${candidate.text}`,
            `URL: ${candidate.url}`
          ].join("\n");
          await appendRequest(requestObj(update, "evaluate", requestText, true), SR_QUEUE);
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "🧠 Candidato enviado para evaluar." });
          await safeTelegram("deleteMessage", { chat_id: allowedChat, message_id: msg.message_id });
        }
      } else if (data.startsWith("sr:delete:")) {
        await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "🗑️ Candidato quitado." });
        await telegram("deleteMessage", { chat_id: allowedChat, message_id: msg.message_id });
      } else if (data.startsWith("dg:")) {
        const ids=data.slice(3).split(",").map(x=>Number(x)).filter(Number.isInteger);
        if (msg.message_id && !ids.includes(Number(msg.message_id))) ids.push(Number(msg.message_id));
        let deleted=0;
        for (const mid of ids) { const r=await safeTelegram("deleteMessage",{chat_id:allowedChat,message_id:mid}); if(r!==null) deleted++; }
        await safeTelegram("answerCallbackQuery",{callback_query_id:cq.id,text:`🗑️ Borrados ${deleted} mensajes.`});
      } else if (data === "delete:message") {
        await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "🗑️ Quitado." });
        await telegram("deleteMessage", { chat_id: allowedChat, message_id: msg.message_id });
      } else if (data.startsWith("prepare:")) {
        const original = msg.text || "";
        const headline = extractPreparedHeadline(original, data);
        if (headline) {
          await appendRequest(requestObj(update, "prepare", `Prepara la noticia: ${headline}`, true), NEWS_QUEUE);
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "✅ Añadida para preparar." });
          const valuationCount = (original.match(/^N\d+\.\s+/gm) || []).length;
          if (valuationCount <= 1) {
            await safeTelegram("deleteMessage", { chat_id: allowedChat, message_id: msg.message_id });
          }
        }
      } else if (data === "run:bulletin") {
        await appendRequest(requestObj(update, "run", "Ejecuta ahora un boletín manual de TTiTTulares.", true), NEWS_QUEUE);
        await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "✅ Solicitud de boletín registrada." });
      } else if (data === "run:trends") {
        await appendRequest(requestObj(update, "run", "Ejecuta ahora TTendencias.", true), TRENDS_QUEUE);
        await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "✅ Solicitud TTendencias registrada." });
      } else {
        await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id });
      }
      return res.status(200).json({ ok: true });
    }

    const message = update.message || {};
    const chatId = String((message.chat || {}).id || "");
    if (chatId !== allowedChat) return res.status(200).json({ ok: true });
    const text = (message.text || "").trim();
    if (!text) return res.status(200).json({ ok: true });
    const reply = message.reply_to_message || {};
    const replyText = (reply.text || reply.caption || "").trim();
    const mediaMatch = replyText.match(/^🚨 TT Control · RADAR ·/m);
    const controlMatch = text.match(/^CONTROL\\b\\s*[:\\-]?\\s*(.*)$/is);
    if (controlMatch) {
      const instruction=(controlMatch[1]||"").trim();
      if(!instruction) { await safeTelegram("sendMessage",{chat_id:allowedChat,text:"Escribe la consigna después de CONTROL."}); return res.status(200).json({ok:true}); }
      const contextual=replyText ? instruction+"\\n\\nContexto del mensaje respondido:\\n"+replyText : instruction;
      const rr=await fetch("https://tt-control.fabricelop.workers.dev/api/control",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({text:contextual})});
      if(rr.ok) await safeTelegram("sendMessage",{chat_id:allowedChat,text:replyText?"📝 Consigna CONTROL guardada para esta noticia.":"📝 Consigna CONTROL general guardada."});
      else await safeTelegram("sendMessage",{chat_id:allowedChat,text:"No se pudo guardar la consigna CONTROL."});
      return res.status(200).json({ok:true});
    }
    if (replyText && mediaMatch && !text.startsWith("/")) {
      const contextual=text+"\\n\\nContexto del mensaje respondido:\\n"+replyText;
      const rr=await fetch("https://tt-control.fabricelop.workers.dev/api/control",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({text:contextual})});
      if(rr.ok) await safeTelegram("sendMessage",{chat_id:allowedChat,text:"📝 Instrucción guardada para esta noticia."});
      else await safeTelegram("sendMessage",{chat_id:allowedChat,text:"No se pudo guardar la instrucción."});
      return res.status(200).json({ok:true});
    }
    const normalized = text.toLocaleLowerCase("es-ES").replace(/[.!]+$/g, "").trim();
    const first = text.split(/\s+/)[0].toLowerCase();
    const isNewsRun = first === "/boletin" || normalized === "ejecuta" || normalized === "ejecutar" || normalized === "ejecuta boletín" || normalized === "ejecuta boletin";
    const isTrendsRun = first === "/tendencias" || normalized === "ejecuta tendencias" || normalized === "ejecuta ttendencias";
    if (isTrendsRun) {
      const added = await appendRequest(requestObj(update, "run", "Ejecuta ahora TTendencias.", true), TRENDS_QUEUE);
      if (added) await safeTelegram("sendMessage", { chat_id: allowedChat, text: "▶️ Solicitud TTendencias registrada." });
    } else if (isNewsRun) {
      const added = await appendRequest(requestObj(update, "run", "Ejecuta ahora un boletín manual de TTiTTulares.", true), NEWS_QUEUE);
      if (added) await safeTelegram("sendMessage", { chat_id: allowedChat, text: "▶️ Solicitud de boletín registrada." });
    } else if (!text.startsWith("/")) {
      if (replyText && isTrendMessage(replyText)) {
        const storedText=`Instrucción: ${text}\nMensaje al que responde:\n${replyText}`;
        const added=await appendRequest(requestObj(update,"instruction",storedText),TRENDS_QUEUE);
        if(added) await safeTelegram("sendMessage",{chat_id:allowedChat,text:"🟣 Instrucción TTendencias guardada."});
      } else if (replyText) {
        const contextual=text+"\n\nContexto del mensaje respondido:\n"+replyText;
        const rr=await fetch("https://tt-control.fabricelop.workers.dev/api/control",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({text:contextual})});
        if(rr.ok) await safeTelegram("sendMessage",{chat_id:allowedChat,text:"📝 Instrucción guardada para esta noticia."});
      } else {
        const eventId="manual-"+String(update.update_id||message.message_id||Date.now());
        await upsertEditorialProcessing(eventId,text,"");
        await appendRequest(requestObj(update,"manual_headline",text),EMERGENCY_QUEUE);
        await safeTelegram("sendMessage",{chat_id:allowedChat,text:"✅ Titular añadido a Elaborando."});
      }
    }
    return res.status(200).json({ ok: true });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false, error: String(e.message || e) });
  }
}
