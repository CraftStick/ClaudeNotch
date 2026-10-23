# Claude Notch's Telegram bot

A Cloudflare Worker with a D1 database. The app gets a one-time code from it, you send the code to the
bot, and from then on the app's notifications for that Mac go to your chat. It keeps a hash of the Mac's
secret, the chat id and its name; the messages themselves are passed on and forgotten.

## Deploy

```bash
cd Server
npx wrangler@4 login
npx wrangler@4 d1 create claude-notch-bot          # put the database_id it prints into wrangler.toml
npx wrangler@4 d1 execute claude-notch-bot --remote --file schema.sql
npx wrangler@4 secret put BOT_TOKEN                 # the token from @BotFather
npx wrangler@4 secret put WEBHOOK_SECRET            # any long random string, e.g. `openssl rand -hex 32`
npx wrangler@4 deploy
curl -X POST https://<the worker's address>/setup -H "X-Setup-Key: <WEBHOOK_SECRET>"
```

Then put the worker's address into `Telegram.server` in `Sources/App/Support/Telegram.swift`.

To update it, `npx wrangler@4 deploy` again. A database made before `throttle` gets the table from the worker
itself, or from running `schema.sql` again, which only adds what's missing.
