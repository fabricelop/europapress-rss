CREATE TABLE IF NOT EXISTS jobs (
 id TEXT PRIMARY KEY,
 target TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('queued','running','diagnosed','triggered_unverified','failed','needs_configuration')),
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL,
 expires_at TEXT NOT NULL,
 detail TEXT DEFAULT '',
 lease TEXT
);
CREATE INDEX IF NOT EXISTS jobs_by_queue ON jobs (state, created_at);
