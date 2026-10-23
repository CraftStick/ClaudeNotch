-- A Mac that asked for a code: the SHA-256 of its secret, and the chat it's linked to, if any.
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    chat_id INTEGER,
    chat_name TEXT,
    created INTEGER NOT NULL,
    -- Messages sent in the current hour (starting at sent_window), against a runaway loop.
    sent_window INTEGER NOT NULL DEFAULT 0,
    sent_count INTEGER NOT NULL DEFAULT 0
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
