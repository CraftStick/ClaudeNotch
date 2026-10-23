-- A Mac that asked for a code: the SHA-256 of its secret, and the chat it's linked to, if any.
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    chat_id INTEGER,
    chat_name TEXT,
    -- What to send: a JSON list of the app's kinds of notification; NULL until the app says.
    prefs TEXT,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_chat ON devices (chat_id);

-- One-time codes waiting to be sent to the bot.
CREATE TABLE IF NOT EXISTS codes (
    code TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    expires INTEGER NOT NULL
);

-- Buttons pressed under a question, until the Mac picks them up.
CREATE TABLE IF NOT EXISTS answers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    data TEXT NOT NULL,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS answers_chat ON answers (chat_id);

-- Uses this hour, against a runaway loop or someone filling the database: messages and edits by chat,
-- codes by a hash of the address that asked. The worker makes the table too if it isn't there.
CREATE TABLE IF NOT EXISTS throttle (
    name TEXT PRIMARY KEY,
    hour INTEGER NOT NULL,
    uses INTEGER NOT NULL
);

-- A database made before `prefs` was there gets it with:
-- ALTER TABLE devices ADD COLUMN prefs TEXT;
-- (One from before `throttle` keeps its unused sent_window and sent_count columns.)
