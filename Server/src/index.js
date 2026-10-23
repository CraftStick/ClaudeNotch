// Claude Notch's Telegram bot, as a Cloudflare Worker. A Mac gets a one-time code from it, you send
// that code to the bot, and from then on the app's notifications for that Mac reach your chat.
//
// The app's side (all under /v1/, with `Authorization: Bearer <the Mac's own random secret>`):
//   POST   /v1/code    a new code to send the bot (good for 15 minutes)
//   GET    /v1/status  whether the Mac is linked to a chat, and to whose
//   POST   /v1/notify  {"text": "…"}: a message to the linked chat
//   DELETE /v1/link    unlinks it
// Telegram's side: POST /telegram, the bot's webhook, set up once with POST /setup.
//
// Kept about a Mac: a hash of its secret, the chat id and its name. Nothing about Claude's work: the
// messages are passed on and forgotten.

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

  const row = await env.DB.prepare("SELECT chat_id, chat_name, sent_window, sent_count FROM devices WHERE id = ?").bind(device).first()
  const linked = row != null && row.chat_id != null

  if (route === "status" && request.method === "GET") {
    return json({ linked, name: linked ? row.chat_name : null, bot: await botName(env) })
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
    const text = typeof body.text === "string" ? body.text.trim().slice(0, 1500) : ""
    if (!text) return json({ error: "empty" }, 400)
    const hour = now - (now % 3600)
    const count = row.sent_window === hour ? row.sent_count + 1 : 1
    if (count > HOURLY_MESSAGES) return json({ error: "too_many" }, 429)
    await env.DB.prepare("UPDATE devices SET sent_window = ?, sent_count = ? WHERE id = ?").bind(hour, count, device).run()
    const sent = await send(env, row.chat_id, text)
    if (sent.status === 403) {  // the bot was blocked or the chat is gone
      await env.DB.prepare("UPDATE devices SET chat_id = NULL, chat_name = NULL WHERE id = ?").bind(device).run()
      return json({ error: "not_linked" }, 410)
    }
    return sent.ok ? json({ ok: true }) : json({ error: "telegram" }, 502)
  }

  return json({ error: "not_found" }, 404)
}

// MARK: - Telegram

async function webhook(request, env) {
  if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.WEBHOOK_SECRET) return new Response("", { status: 401 })
  const update = await request.json().catch(() => ({}))
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
      "Готово, Mac подключён! Сюда будут приходить уведомления Claude Notch: какие именно, выбери в настройках приложения.\n\n/stop — отключить.",
      "Done, the Mac is linked! Claude Notch's notifications will come here: pick which ones in the app's settings.\n\n/stop to unlink."))
    return new Response("")
  }

  await send(env, chat, say(lang,
    "Привет! Я присылаю уведомления Claude Notch: например, когда закончились лимиты Claude.\n\nЧтобы подключить Mac, открой Claude Notch → Настройки → Уведомления, нажми «Получить код» и пришли его сюда.",
    "Hi! I send Claude Notch's notifications: say, when your Claude limits run out.\n\nTo link your Mac, open Claude Notch → Settings → Notifications, click Get Code and send it here."))
  return new Response("")
}

// Points Telegram at this worker. Run once after deploying:
// curl -X POST https://<worker>/setup -H "X-Setup-Key: <WEBHOOK_SECRET>"
async function setup(request, env, url) {
  if (request.headers.get("X-Setup-Key") !== env.WEBHOOK_SECRET) return json({ error: "unauthorized" }, 401)
  const webhook = await telegram(env, "setWebhook", {
    url: `${url.origin}/telegram`,
    secret_token: env.WEBHOOK_SECRET,
    allowed_updates: ["message"],
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

function send(env, chat, text) {
  return telegram(env, "sendMessage", { chat_id: chat, text, disable_web_page_preview: true })
}

function telegram(env, method, body) {
  return fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
}

// MARK: - Bits

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
