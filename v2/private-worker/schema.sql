CREATE TABLE IF NOT EXISTS red_marks (
 trend_id TEXT PRIMARY KEY NOT NULL,
 entered_top30_at TEXT NOT NULL,
 marked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
