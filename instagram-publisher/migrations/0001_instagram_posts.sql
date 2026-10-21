-- Separate D1 database. Do NOT run against existing TT Control databases.
CREATE TABLE IF NOT EXISTS instagram_posts (
 id TEXT PRIMARY KEY,
 source TEXT NOT NULL CHECK(source IN ('ttittulares','ttendencias')),
 event_id TEXT NOT NULL,
 revision INTEGER NOT NULL,
 telegram_message_id INTEGER NOT NULL,
 image_url TEXT NOT NULL,
 caption TEXT NOT NULL,
 state TEXT NOT NULL,
 container_id TEXT,
 media_id TEXT,
 permalink TEXT,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS instagram_posts_by_state ON instagram_posts(state);
