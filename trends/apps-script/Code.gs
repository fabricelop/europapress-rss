/**
 * TTendencias España - Telegram webhook
 *
 * Script Properties requeridas:
 * BOT_TOKEN       Token del bot dedicado de TTendencias
 * GITHUB_TOKEN    Fine-grained PAT con Contents: Read and write solo para el repo
 * GITHUB_REPO     fabricelop/europapress-rss
 * GITHUB_BRANCH   main
 * WEBHOOK_KEY     Cadena aleatoria privada
 * WEB_APP_URL     URL /exec del despliegue Apps Script
 */

const PROPS = PropertiesService.getScriptProperties();

function doGet(e) {
  return ContentService
    .createTextOutput(JSON.stringify({ ok: true, service: 'TTendencias webhook' }))
    .setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  try {
    if (!e || !e.parameter || e.parameter.key !== prop_('WEBHOOK_KEY')) {
      return json_({ ok: false, error: 'unauthorized' });
    }

    const update = JSON.parse((e.postData && e.postData.contents) || '{}');
    const cb = update.callback_query;

    if (!cb) {
      return json_({ ok: true, ignored: true });
    }

    const data = String(cb.data || '');

    if (data.indexOf('trend:') === 0) {
      handleTrend_(cb);
    } else if (data.indexOf('explained:') === 0) {
      handleExplained_(cb);
    } else if (data.indexOf('close:') === 0) {
      handleClose_(cb);
    } else {
      answerCallback_(cb.id, 'Acción no reconocida');
    }

    return json_({ ok: true });
  } catch (err) {
    console.error(err && err.stack ? err.stack : err);
    return json_({ ok: false, error: String(err) });
  }
}

function installWebhook() {
  const url = prop_('WEB_APP_URL') + '?key=' + encodeURIComponent(prop_('WEBHOOK_KEY'));
  const result = bot_('setWebhook', {
    url: url,
    allowed_updates: ['callback_query'],
    drop_pending_updates: false
  });
  console.log(JSON.stringify(result));
  return result;
}

function webhookInfo() {
  const result = bot_('getWebhookInfo', {});
  console.log(JSON.stringify(result));
  return result;
}

function removeWebhook() {
  const result = bot_('deleteWebhook', { drop_pending_updates: false });
  console.log(JSON.stringify(result));
  return result;
}

function handleTrend_(cb) {
  const message = cb.message || {};
  const match = /^trend:(\d+)$/.exec(String(cb.data || ''));
  if (!match) {
    answerCallback_(cb.id, 'Selección inválida');
    return;
  }

  const rank = Number(match[1]);
  const info = trendFromKeyboard_(message, cb.data, rank);
  if (!info.name) {
    answerCallback_(cb.id, 'No se pudo identificar la tendencia');
    return;
  }

  // Camino crítico: Telegram primero.
  answerCallback_(cb.id, '🔵 En preparación');
  paintPreparing_(message, cb.data);

  // Persistencia después. Si GitHub falla, el usuario ya recibió respuesta;
  // el error queda en los logs de Apps Script para reintento/diagnóstico.
  enqueueGithub_(info.name, rank);
}

function handleExplained_(cb) {
  const key = String(cb.data || '').split(':').slice(1).join(':');
  answerCallback_(cb.id, '✅ Explicada');

  const message = cb.message || {};
  if (message.chat && message.message_id) {
    try {
      bot_('deleteMessage', {
        chat_id: message.chat.id,
        message_id: message.message_id
      });
    } catch (err) {
      console.error('deleteMessage:', err);
    }
  }

  markExplainedGithub_(key);
}

function handleClose_(cb) {
  answerCallback_(cb.id, 'Cerrado');
  const message = cb.message || {};
  if (message.chat && message.message_id) {
    try {
      bot_('deleteMessage', {
        chat_id: message.chat.id,
        message_id: message.message_id
      });
    } catch (err) {
      console.error('deleteMessage:', err);
    }
  }
}

function paintPreparing_(message, callbackData) {
  if (!message.chat || !message.message_id || !message.reply_markup) return;

  const keyboard = JSON.parse(JSON.stringify(message.reply_markup.inline_keyboard || []));
  let changed = false;

  keyboard.forEach(function(row) {
    row.forEach(function(button) {
      if (button.callback_data === callbackData) {
        button.text = String(button.text || '').replace(/^[🔴🟡🟢🔵]/u, '🔵');
        changed = true;
      }
    });
  });

  if (!changed) return;

  bot_('editMessageReplyMarkup', {
    chat_id: message.chat.id,
    message_id: message.message_id,
    reply_markup: { inline_keyboard: keyboard }
  });
}

function trendFromKeyboard_(message, callbackData, fallbackRank) {
  const keyboard = (((message || {}).reply_markup || {}).inline_keyboard) || [];
  for (let i = 0; i < keyboard.length; i++) {
    for (let j = 0; j < keyboard[i].length; j++) {
      const button = keyboard[i][j];
      if (button.callback_data !== callbackData) continue;

      const text = String(button.text || '');
      const m = /^[🔴🟡🟢🔵]\s*(\d+)\s+(.+)$/u.exec(text);
      if (m) return { rank: Number(m[1]), name: m[2].trim() };

      // Formato defensivo por si Telegram conserva espacios distintos.
      const stripped = text.replace(/^[🔴🟡🟢🔵]/u, '').trim();
      const m2 = /^(\d+)\s+(.+)$/.exec(stripped);
      if (m2) return { rank: Number(m2[1]), name: m2[2].trim() };
    }
  }
  return { rank: fallbackRank, name: '' };
}

function enqueueGithub_(name, rank) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    mutateGithubJson_('trends/requests.json', function(doc) {
      doc = doc || { requests: [] };
      doc.requests = doc.requests || [];

      const normalized = norm_(name);
      const exists = doc.requests.some(function(item) {
        return norm_(item.name) === normalized &&
          ['preparing', 'ready'].indexOf(String(item.status || '')) >= 0;
      });

      if (!exists) {
        doc.requests.push({
          id: sha12_(name),
          name: name,
          rank: rank,
          status: 'preparing',
          requested_at: madridIso_(),
          revision: 0,
          reexplain: false,
          source: 'telegram_webhook'
        });
      }
      return doc;
    }, 'Seleccionar TTendencia desde Telegram');
  } finally {
    lock.releaseLock();
  }
}

function markExplainedGithub_(id) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    let selectedName = '';

    mutateGithubJson_('trends/requests.json', function(doc) {
      doc = doc || { requests: [] };
      doc.requests = doc.requests || [];

      doc.requests.forEach(function(item) {
        if (String(item.id || '') === id &&
            ['preparing', 'ready', 'update'].indexOf(String(item.status || '')) >= 0) {
          selectedName = String(item.name || '');
          item.status = 'explained';
          item.explained_at = madridIso_();
        }
      });
      return doc;
    }, 'Marcar TTendencia explicada');

    if (selectedName) {
      mutateGithubJson_('trends/telegram-manual-explained.json', function(doc) {
        doc = doc || { project: 'TTendencias', items: [] };
        doc.items = doc.items || [];

        const n = norm_(selectedName);
        const exists = doc.items.some(function(item) {
          return norm_(item.name) === n;
        });

        if (!exists) {
          doc.items.push({
            name: selectedName,
            explained_at: madridIso_(),
            source: 'telegram_webhook'
          });
        }
        return doc;
      }, 'Registrar TTendencia explicada');
    }
  } finally {
    lock.releaseLock();
  }
}

function mutateGithubJson_(path, mutator, message) {
  const repo = prop_('GITHUB_REPO');
  const branch = propOr_('GITHUB_BRANCH', 'main');
  const token = prop_('GITHUB_TOKEN');
  const url = 'https://api.github.com/repos/' + repo + '/contents/' + path;

  for (let attempt = 1; attempt <= 3; attempt++) {
    const current = githubGet_(url + '?ref=' + encodeURIComponent(branch), token);
    const decoded = Utilities.newBlob(
      Utilities.base64Decode(String(current.content || '').replace(/\s/g, ''))
    ).getDataAsString('UTF-8');

    const doc = decoded ? JSON.parse(decoded) : {};
    const next = mutator(doc);
    const content = Utilities.base64Encode(
      Utilities.newBlob(JSON.stringify(next, null, 2) + '\n').getBytes()
    );

    const response = UrlFetchApp.fetch(url, {
      method: 'put',
      muteHttpExceptions: true,
      contentType: 'application/json',
      headers: githubHeaders_(token),
      payload: JSON.stringify({
        message: message,
        content: content,
        sha: current.sha,
        branch: branch
      })
    });

    const code = response.getResponseCode();
    if (code >= 200 && code < 300) {
      return JSON.parse(response.getContentText());
    }

    if (code !== 409 && code !== 422) {
      throw new Error('GitHub PUT ' + path + ': ' + code + ' ' + response.getContentText());
    }

    Utilities.sleep(attempt * 250);
  }

  throw new Error('GitHub conflict persistente en ' + path);
}

function githubGet_(url, token) {
  const response = UrlFetchApp.fetch(url, {
    method: 'get',
    muteHttpExceptions: true,
    headers: githubHeaders_(token)
  });
  const code = response.getResponseCode();
  if (code < 200 || code >= 300) {
    throw new Error('GitHub GET: ' + code + ' ' + response.getContentText());
  }
  return JSON.parse(response.getContentText());
}

function githubHeaders_(token) {
  return {
    Authorization: 'Bearer ' + token,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'TTendencias-Apps-Script'
  };
}

function answerCallback_(id, text) {
  try {
    bot_('answerCallbackQuery', {
      callback_query_id: id,
      text: text,
      cache_time: 0
    });
  } catch (err) {
    console.error('answerCallbackQuery:', err);
  }
}

function bot_(method, payload) {
  const url = 'https://api.telegram.org/bot' + prop_('BOT_TOKEN') + '/' + method;
  const response = UrlFetchApp.fetch(url, {
    method: 'post',
    muteHttpExceptions: true,
    contentType: 'application/json',
    payload: JSON.stringify(payload || {})
  });

  const body = response.getContentText();
  const result = JSON.parse(body || '{}');
  if (!result.ok) {
    throw new Error('Telegram ' + method + ': ' + body);
  }
  return result.result;
}

function prop_(name) {
  const value = PROPS.getProperty(name);
  if (!value) throw new Error('Falta Script Property: ' + name);
  return value;
}

function propOr_(name, fallback) {
  return PROPS.getProperty(name) || fallback;
}

function norm_(value) {
  return String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

function sha12_(value) {
  const bytes = Utilities.computeDigest(
    Utilities.DigestAlgorithm.SHA_256,
    value,
    Utilities.Charset.UTF_8
  );
  return bytes.map(function(b) {
    const v = b < 0 ? b + 256 : b;
    return ('0' + v.toString(16)).slice(-2);
  }).join('').slice(0, 12);
}

function madridIso_() {
  return Utilities.formatDate(
    new Date(),
    'Europe/Madrid',
    "yyyy-MM-dd'T'HH:mm:ssXXX"
  );
}

function json_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
