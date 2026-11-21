-- Private database: NO anonymous access / no public records API.
CREATE TABLE IF NOT EXISTS image_candidates (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL CHECK (project IN ('ttendencias','ttittulares')),
  editorial_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 0),
  episode_fingerprint TEXT NOT NULL,
  command_id TEXT NOT NULL,
  raster_sha256 TEXT NOT NULL,
  object_key TEXT NOT NULL,
  title TEXT NOT NULL,
  editorial_text TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN
    ('pending','rejected','approved_awaiting_publication','published')),
  created_at TEXT NOT NULL,
  decided_at TEXT,
  decided_by TEXT,
  published_app_at TEXT,
  published_sites_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_image_candidates_inbox ON image_candidates(status,created_at);