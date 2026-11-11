-- TT Fotos private editor image store. Independent from image-inbox/iPhone.
CREATE TABLE IF NOT EXISTS tt_fotos_assets (
  sha TEXT PRIMARY KEY CHECK (length(sha)=64),
  size_bytes INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  conversation_url TEXT,
  evidence_command TEXT,
  evidence_reason TEXT NOT NULL,
  title TEXT
);
CREATE TABLE IF NOT EXISTS tt_fotos_matches (
  project TEXT NOT NULL CHECK(project IN ('ttittulares','ttendencias')),
  editorial_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  command_id TEXT NOT NULL,
  asset_sha TEXT NOT NULL REFERENCES tt_fotos_assets(sha),
  confidence TEXT NOT NULL CHECK(confidence IN ('auto_exact','editor_confirmed')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, editorial_id, revision, command_id)
);
CREATE TABLE IF NOT EXISTS tt_fotos_match_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  editorial_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  command_id TEXT NOT NULL,
  asset_sha TEXT NOT NULL,
  confidence TEXT NOT NULL,
  changed_at TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('associate','replace'))
);
CREATE INDEX IF NOT EXISTS idx_tt_fotos_match_asset ON tt_fotos_matches(asset_sha);
CREATE INDEX IF NOT EXISTS idx_tt_fotos_assets_created ON tt_fotos_assets(created_at);
CREATE INDEX IF NOT EXISTS idx_tt_fotos_history_command ON tt_fotos_match_history(command_id,changed_at);
CREATE TABLE IF NOT EXISTS tt_fotos_jobs (
  command_id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  editorial_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  requested_at TEXT,
  conversation_url TEXT,
  registered_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tt_fotos_jobs_requested ON tt_fotos_jobs(requested_at);