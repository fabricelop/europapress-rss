from pathlib import Path

p = Path("api/telegram-webhook.js")
s = p.read_text(encoding="utf-8")
marker = '      if (data.startsWith("tt:")) {'
if 'data.startsWith("tx:")' in s:
    print("Callback tx ya instalado")
    raise SystemExit(0)

block = r'''      if (data.startsWith("tx:")) {
        const parts = data.split(":");
        const action = parts[1] || "";
        const id = parts[2] || "";
        const revision = Number(parts[3] || 0);
        if (!["p", "d"].includes(action) || !id) {
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "Acción no válida." });
          return res.status(200).json({ ok: true, ignored: true });
        }
        const status = action === "p" ? "published" : "dismissed";
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
          await mutateTrendJson("trends/telegram-image-deliveries.json", (doc) => {
            let changed = false;
            for (const row of (doc.items || [])) {
              if (String(row.event_id || "") !== id || Number(row.revision || 0) !== revision) continue;
              matched = true; changed = true; row.status = status; row.decision_source = "telegram_webhook";
              row[status === "published" ? "published_at" : "dismissed_at"] = now;
              for (const k of ["telegram_message_id", "archive_telegram_message_id"]) { const mid = Number(row[k] || 0); if (mid && !mids.includes(mid)) mids.push(mid); }
            }
            if (changed) doc.updated_at = now;
            return changed;
          });
          await mutateTrendJson("trends/telegram-manual-explained.json", (doc) => {
            let changed = false;
            for (const row of (doc.items || [])) {
              if (String(row.id || "") !== id || Number(row.revision || 0) !== revision) continue;
              matched = true; changed = true; row.telegram_package_status = status; row.telegram_package_updated_at = now; row.telegram_decision_source = "telegram_webhook";
              row[status === "published" ? "telegram_published_at" : "telegram_dismissed_at"] = now;
            }
            if (changed) doc.updated_at = now;
            return changed;
          });
          const currentMid = Number(msg.message_id || 0); if (currentMid && !mids.includes(currentMid)) mids.push(currentMid);
          if (!matched) { await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "No encuentro el paquete vigente.", show_alert: true }); return res.status(200).json({ ok: false, matched: false }); }
          for (const mid of mids) await safeTelegram("deleteMessage", { chat_id: allowedChat, message_id: mid });
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: status === "published" ? "Publicada." : "Desestimada." });
          return res.status(200).json({ ok: true, status, event_id: id, revision, deleted: mids.length });
        } catch (e) {
          console.error("TTendencias callback persistence failed", { id, revision, status, error: String(e?.message || e) });
          await safeTelegram("answerCallbackQuery", { callback_query_id: cq.id, text: "No se pudo guardar el estado. El mensaje se conserva.", show_alert: true });
          return res.status(200).json({ ok: false, status, event_id: id, revision });
        }
      } else if (data.startsWith("tt:")) {'''

if marker not in s:
    raise SystemExit("No se encontró el punto de inserción")
p.write_text(s.replace(marker, block, 1), encoding="utf-8")
print("Parche tx instalado")
