// Claude Notch's Telegram bot, as a Cloudflare Worker. A Mac gets a one-time code from it, you send
// that code to the bot, and from then on the app's notifications for that Mac reach your chat.
//
// The app's side (all under /v1/, with `Authorization: Bearer <the Mac's own random secret>`):
//   POST   /v1/code    a new code to send the bot (good for 15 minutes)
//   GET    /v1/status  whether the Mac is linked to a chat, and to whose
//   POST   /v1/notify  {"text": "…", "html": true, "buttons": [[{"text", "data"}]]}: a message to the linked
//                      chat, in Telegram's HTML if asked, with buttons under it; answers {"message_id"}
//   POST   /v1/edit    {"message_id", "text", "html", "buttons"}: that message changed, without buttons if none
//   GET    /v1/answers the buttons pressed since the last look: {"answers": ["<data>", …]}
//   POST   /v1/prefs   {"enabled": ["limitReached", …]}: what to send, also switched in the chat's Features;
//                      /v1/status hands it back, and /v1/notify drops a message whose "kind" is off
//   DELETE /v1/link    unlinks it
// Telegram's side: POST /telegram, the bot's webhook, set up once with POST /setup.
//
// Kept about a Mac: a hash of its secret, the chat id and its name; and a button pressed, until the
// Mac picks it up. Nothing about Claude's work: the messages are passed on and forgotten.

const CODE_TTL = 15 * 60
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // no 0/O, 1/I: easy to type over
const CODE_LENGTH = 8
// Messages a Mac may send an hour: more is a loop gone wrong.
const HOURLY_MESSAGES = 60

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    try {
      if (url.pathname === "/telegram" && request.method === "POST") return await webhook(request, env)
      if (url.pathname === "/setup" && request.method === "POST") return await setup(request, env, url)
      if (url.pathname.startsWith("/v1/")) return await api(request, env, url.pathname.slice(4))
      return new Response("Claude Notch bot\n")
    } catch (error) {
      console.error(error)
      return json({ error: "internal" }, 500)
    }
  },
}

// MARK: - The app

async function api(request, env, route) {
  const secret = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "")
  if (secret.length < 32 || secret.length > 128) return json({ error: "unauthorized" }, 401)
  const device = await sha256(secret)
  const now = Math.floor(Date.now() / 1000)

  if (route === "code" && request.method === "POST") {
    await env.DB.batch([
      env.DB.prepare("INSERT OR IGNORE INTO devices (id, created) VALUES (?, ?)").bind(device, now),
      env.DB.prepare("DELETE FROM codes WHERE device_id = ? OR expires < ?").bind(device, now),
    ])
    const code = randomCode()
    await env.DB.prepare("INSERT INTO codes (code, device_id, expires) VALUES (?, ?, ?)").bind(code, device, now + CODE_TTL).run()
    const bot = await botName(env)
    return json({ code, expires: now + CODE_TTL, bot, link: `https://t.me/${bot}?start=${code}` })
  }

  const row = await env.DB.prepare("SELECT chat_id, chat_name, sent_window, sent_count, prefs FROM devices WHERE id = ?").bind(device).first()
  const linked = row != null && row.chat_id != null

  if (route === "status" && request.method === "GET") {
    return json({ linked, name: linked ? row.chat_name : null, bot: await botName(env), prefs: row && row.prefs ? JSON.parse(row.prefs) : null })
  }

  if (route === "prefs" && request.method === "POST") {
    const body = await request.json().catch(() => ({}))
    const enabled = Array.isArray(body.enabled) ? body.enabled.filter((k) => NOTES.some((n) => n.key === k)) : null
    if (!enabled || !row) return json({ error: "bad_request" }, 400)
    await env.DB.prepare("UPDATE devices SET prefs = ? WHERE id = ?").bind(JSON.stringify(enabled), device).run()
    return json({ ok: true })
  }

  if (route === "link" && request.method === "DELETE") {
    if (linked) {
      await env.DB.prepare("UPDATE devices SET chat_id = NULL, chat_name = NULL WHERE id = ?").bind(device).run()
      await send(env, row.chat_id, say(null, "Mac отключён: уведомления Claude Notch сюда больше не придут.",
                                       "The Mac is unlinked: Claude Notch's notifications won't come here any more."))
    }
    return json({ linked: false })
  }

  if (route === "notify" && request.method === "POST") {
    if (!linked) return json({ error: "not_linked" }, 410)
    const body = await request.json().catch(() => ({}))
    const text = typeof body.text === "string" ? body.text.trim().slice(0, 3500) : ""
    if (!text) return json({ error: "empty" }, 400)
    // Switched off in the chat since the app last looked: dropped here.
    if (typeof body.kind === "string" && row.prefs && !JSON.parse(row.prefs).includes(body.kind)) return json({ ok: true, skipped: true })
    const markup = keyboard(body.buttons)
    const hour = now - (now % 3600)
    const count = row.sent_window === hour ? row.sent_count + 1 : 1
    if (count > HOURLY_MESSAGES) return json({ error: "too_many" }, 429)
    await env.DB.prepare("UPDATE devices SET sent_window = ?, sent_count = ? WHERE id = ?").bind(hour, count, device).run()
    let sent = await send(env, row.chat_id, text, body.html === true, markup)
    // HTML Telegram won't take (cut short, say): the same as plain text, the animated emoji as plain ones.
    if (sent.status === 400 && body.html === true) sent = await send(env, row.chat_id, plain(text), false, markup)
    if (sent.status === 403) {  // the bot was blocked or the chat is gone
      await env.DB.prepare("UPDATE devices SET chat_id = NULL, chat_name = NULL WHERE id = ?").bind(device).run()
      return json({ error: "not_linked" }, 410)
    }
    if (!sent.ok) return json({ error: "telegram" }, 502)
    const answer = await sent.json().catch(() => ({}))
    return json({ ok: true, message_id: answer.result && answer.result.message_id })
  }

  if (route === "edit" && request.method === "POST") {
    if (!linked) return json({ error: "not_linked" }, 410)
    const body = await request.json().catch(() => ({}))
    const text = typeof body.text === "string" ? body.text.trim().slice(0, 3500) : ""
    if (!text || !Number.isInteger(body.message_id)) return json({ error: "bad_request" }, 400)
    const message = { chat_id: row.chat_id, message_id: body.message_id, text, disable_web_page_preview: true,
                      reply_markup: keyboard(body.buttons) || { inline_keyboard: [] } }
    if (body.html === true) message.parse_mode = "HTML"
    let edited = await telegram(env, "editMessageText", message)
    if (edited.status === 400 && body.html === true) {
      delete message.parse_mode
      message.text = plain(text)
      edited = await telegram(env, "editMessageText", message)
    }
    return json({ ok: edited.ok })
  }

  if (route === "answers" && request.method === "GET") {
    if (!linked) return json({ answers: [] })
    const { results } = await env.DB.prepare("SELECT id, data FROM answers WHERE chat_id = ? ORDER BY id").bind(row.chat_id).all()
    if (results.length > 0) {
      await env.DB.prepare(`DELETE FROM answers WHERE id IN (${results.map(() => "?").join(",")})`).bind(...results.map((r) => r.id)).run()
    }
    await env.DB.prepare("DELETE FROM answers WHERE created < ?").bind(now - 3600).run()
    return json({ answers: results.map((r) => r.data) })
  }

  return json({ error: "not_found" }, 404)
}

// MARK: - Telegram

async function webhook(request, env) {
  if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.WEBHOOK_SECRET) return new Response("", { status: 401 })
  const update = await request.json().catch(() => ({}))
  if (update.callback_query) return await pressed(update.callback_query, env)
  const message = update.message
  if (!message || !message.chat || message.chat.type !== "private" || typeof message.text !== "string") return new Response("")
  const chat = message.chat.id
  const lang = message.from && message.from.language_code
  const text = message.text.trim()

  if (/^\/stop(@\w+)?$/i.test(text)) {
    const { meta } = await env.DB.prepare("UPDATE devices SET chat_id = NULL, chat_name = NULL WHERE chat_id = ?").bind(chat).run()
    await send(env, chat, meta.changes > 0
      ? say(lang, "Готово: Mac отключён, уведомления больше не придут.", "Done: the Mac is unlinked, no more notifications.")
      : say(lang, "К этому чату не подключён ни один Mac.", "No Mac is linked to this chat."))
    return new Response("")
  }

  // "/start CODE" from the app's link, or the code typed in, with or without the dash, in any case.
  const words = text.replace(/^\/start(@\w+)?/i, "").replace(/[\s-]/g, "").toUpperCase()
  if (words.length === CODE_LENGTH && [...words].every((c) => CODE_ALPHABET.includes(c))) {
    const now = Math.floor(Date.now() / 1000)
    const found = await env.DB.prepare("SELECT device_id FROM codes WHERE code = ? AND expires >= ?").bind(words, now).first()
    if (!found) {
      // A code is gone once used: sent again after the link did it, it's no news.
      const linked = await env.DB.prepare("SELECT 1 FROM devices WHERE chat_id = ? LIMIT 1").bind(chat).first()
      if (linked) {
        await send(env, chat, alreadyLinked(lang), true, menu(lang))
        return new Response("")
      }
      await send(env, chat, say(lang, "Код не подошёл или уже устарел. Возьми новый: Claude Notch → Настройки → Уведомления.",
                                      "That code didn't work or has expired. Get a new one: Claude Notch → Settings → Notifications."))
      return new Response("")
    }
    const from = message.from || {}
    const name = from.username ? `@${from.username}` : [from.first_name, from.last_name].filter(Boolean).join(" ") || "Telegram"
    await env.DB.batch([
      env.DB.prepare("UPDATE devices SET chat_id = ?, chat_name = ? WHERE id = ?").bind(chat, name, found.device_id),
      env.DB.prepare("DELETE FROM codes WHERE device_id = ?").bind(found.device_id),
    ])
    await send(env, chat, say(lang,
      "Готово, Mac подключён! Сюда будут приходить уведомления Claude Notch. Какие именно, выбирается здесь, в «Функциях», или в настройках приложения.",
      "Done, the Mac is linked! Claude Notch's notifications will come here. Pick which ones here, under Features, or in the app's settings."), false, menu(lang))
    return new Response("")
  }

  if (await env.DB.prepare("SELECT 1 FROM devices WHERE chat_id = ? LIMIT 1").bind(chat).first()) {
    await send(env, chat, alreadyLinked(lang), true, menu(lang))
    return new Response("")
  }
  await send(env, chat, say(lang,
    "Привет! Я присылаю уведомления Claude Notch: например, когда закончились лимиты Claude.\n\nЧтобы подключить Mac, открой Claude Notch → Настройки → Уведомления, нажми «Получить код» и пришли его сюда.",
    "Hi! I send Claude Notch's notifications: say, when your Claude limits run out.\n\nTo link your Mac, open Claude Notch → Settings → Notifications, click Get Code and send it here."))
  return new Response("")
}

// A button was pressed. The bot's own menu (Features, Unlink, a notification switched) it handles
// itself; one under a question is kept for the Mac to pick up (every Mac linked to the chat looks,
// and the one that asked knows it), and Telegram told it's taken.
async function pressed(query, env) {
  const chat = query.message && query.message.chat && query.message.chat.id
  const data = typeof query.data === "string" ? query.data.slice(0, 64) : ""
  const lang = query.from && query.from.language_code
  if (chat && data.startsWith("menu:")) return await menuPressed(query, env, chat, data.slice(5), lang)
  if (chat && data) {
    await env.DB.prepare("INSERT INTO answers (chat_id, data, created) VALUES (?, ?, ?)").bind(chat, data, Math.floor(Date.now() / 1000)).run()
  }
  await telegram(env, "answerCallbackQuery", { callback_query_id: query.id, text: say(lang, "Принято", "Got it") })
  return new Response("")
}

// MARK: - The menu

// What the app can send, by the app's own names; on unless switched off, these by default.
const NOTES = [
  { key: "limitReached", ru: "Закончился лимит", en: "A limit ran out", on: true },
  { key: "limitBack", ru: "Лимит снова доступен", en: "A limit is back", on: true },
  { key: "question", ru: "Вопросы Claude с кнопками", en: "Claude's questions, with buttons", on: true },
  { key: "done", ru: "Claude закончил задачу", en: "Claude is done", on: false },
  { key: "waiting", ru: "Claude ждёт тебя", en: "Claude is waiting for you", on: false },
  { key: "failed", ru: "Ошибка API", en: "An API error", on: false },
]

function menu(lang) {
  return { inline_keyboard: [[
    { text: say(lang, "⚙️ Функции", "⚙️ Features"), callback_data: "menu:features" },
    { text: say(lang, "🔌 Отключиться", "🔌 Unlink"), callback_data: "menu:unlink" },
  ]] }
}

// What's switched on for the chat's Macs (the first one's choice when there are several).
async function chatPrefs(env, chat) {
  const row = await env.DB.prepare("SELECT prefs FROM devices WHERE chat_id = ? AND prefs IS NOT NULL LIMIT 1").bind(chat).first()
  return row ? JSON.parse(row.prefs) : NOTES.filter((n) => n.on).map((n) => n.key)
}

function featuresPage(lang, enabled) {
  const text = say(lang, "⚙️ Что присылать в этот чат. Нажми, чтобы включить или выключить:",
                         "⚙️ What to send to this chat. Tap to switch on or off:")
  const rows = NOTES.map((n) => [{ text: `${enabled.includes(n.key) ? "✅" : "▫️"} ${say(lang, n.ru, n.en)}`, callback_data: `menu:toggle:${n.key}` }])
  rows.push([{ text: say(lang, "← Назад", "← Back"), callback_data: "menu:back" }])
  return { text, reply_markup: { inline_keyboard: rows } }
}

async function menuPressed(query, env, chat, action, lang) {
  const message = { chat_id: chat, message_id: query.message.message_id }
  let toast = ""
  if (action === "features") {
    Object.assign(message, featuresPage(lang, await chatPrefs(env, chat)))
  } else if (action.startsWith("toggle:")) {
    const key = action.slice(7)
    const note = NOTES.find((n) => n.key === key)
    let enabled = await chatPrefs(env, chat)
    if (note) {
      enabled = enabled.includes(key) ? enabled.filter((k) => k !== key) : [...enabled, key]
      await env.DB.prepare("UPDATE devices SET prefs = ? WHERE chat_id = ?").bind(JSON.stringify(enabled), chat).run()
      toast = `${enabled.includes(key) ? "✅" : "▫️"} ${say(lang, note.ru, note.en)}`
    }
    Object.assign(message, featuresPage(lang, enabled))
  } else if (action === "back") {
    Object.assign(message, { text: alreadyLinked(lang), parse_mode: "HTML", reply_markup: menu(lang) })
  } else if (action === "unlink") {
    await env.DB.prepare("UPDATE devices SET chat_id = NULL, chat_name = NULL WHERE chat_id = ?").bind(chat).run()
    Object.assign(message, { text: say(lang, "🔌 Mac отключён: уведомления больше не придут. Подключить снова: Claude Notch → Настройки → Уведомления.",
                                             "🔌 The Mac is unlinked: no more notifications. To link it again: Claude Notch → Settings → Notifications."),
                             reply_markup: { inline_keyboard: [] } })
  }
  await telegram(env, "editMessageText", message)
  await telegram(env, "answerCallbackQuery", { callback_query_id: query.id, text: toast })
  return new Response("")
}

// Points Telegram at this worker. Run once after deploying:
// curl -X POST https://<worker>/setup -H "X-Setup-Key: <WEBHOOK_SECRET>"
async function setup(request, env, url) {
  if (request.headers.get("X-Setup-Key") !== env.WEBHOOK_SECRET) return json({ error: "unauthorized" }, 401)
  const webhook = await telegram(env, "setWebhook", {
    url: `${url.origin}/telegram`,
    secret_token: env.WEBHOOK_SECRET,
    allowed_updates: ["message", "callback_query"],
    drop_pending_updates: true,
  })
  const commands = await telegram(env, "setMyCommands", { commands: [{ command: "stop", description: "Unlink the Mac" }] })
  const commandsRu = await telegram(env, "setMyCommands", { commands: [{ command: "stop", description: "Отключить Mac" }], language_code: "ru" })
  return json({ webhook: await webhook.json(), commands: (await commands.json()).ok && (await commandsRu.json()).ok, bot: await botName(env) })
}

let cachedBotName = null

async function botName(env) {
  if (!cachedBotName) {
    const me = await (await telegram(env, "getMe", {})).json()
    cachedBotName = me.ok ? me.result.username : null
  }
  return cachedBotName
}

function send(env, chat, text, html = false, markup = null) {
  const message = { chat_id: chat, text, disable_web_page_preview: true }
  if (html) message.parse_mode = "HTML"
  if (markup) message.reply_markup = markup
  return telegram(env, "sendMessage", message)
}

// The app's [[{text, data}]] as Telegram's inline keyboard; null without buttons.
function keyboard(buttons) {
  if (!Array.isArray(buttons)) return null
  const rows = buttons.filter(Array.isArray).slice(0, 8).map((row) => row.slice(0, 4)
    .filter((b) => b && typeof b.text === "string" && typeof b.data === "string" && b.data.length <= 64)
    .map((b) => ({ text: b.text.slice(0, 120), callback_data: b.data }))).filter((row) => row.length > 0)
  return rows.length > 0 ? { inline_keyboard: rows } : null
}

// Telegram's HTML as the text it shows: tags out, entities back.
function plain(html) {
  return html.replace(/<[^>]*>?/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&")
}

function telegram(env, method, body) {
  return fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
}

// MARK: - Bits

// What a linked chat hears when it sends /start or a code again.
function alreadyLinked(lang) {
  const crab = '<tg-emoji emoji-id="5296674469677409218">🦀</tg-emoji>'
  return say(lang,
    `${crab} Привет! Это чат с уведомлениями Claude Notch. Какие именно, выбирается в «Функциях» или в настройках приложения.`,
    `${crab} Hi! This is the chat for Claude Notch's notifications. Pick which ones under Features or in the app's settings.`)
}

function say(lang, ru, en) {
  return lang == null || String(lang).startsWith("ru") ? ru : en
}

function randomCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH))
  return [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("")
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}
