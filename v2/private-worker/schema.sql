CREATE TABLE IF NOT EXISTS red_marks (
 trend_id TEXT PRIMARY KEY NOT NULL,
 entered_top30_at TEXT NOT NULL,
 marked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Isolated V2 ImageGen originals; never the tiny pilot thumbnail.
CREATE TABLE IF NOT EXISTS v2_images (
  trend_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  command_id TEXT NOT NULL UNIQUE,
  editorial_sha256 TEXT NOT NULL,
  raster_sha256 TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  content_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (trend_id, revision)
);

-- Solo un snapshot autoritativo de lectura del Top30 V2.
-- Sin publicaciones ni escrituras en V1; no sustituye cola editorial GitHub.
CREATE TABLE IF NOT EXISTS v2_radar (
 id INTEGER PRIMARY KEY CHECK(id=1),
 payload TEXT NOT NULL,
 updated_at TEXT NOT NULL
);

-- Solo solicitudes RE V2. No modifica ninguna tabla V1.
CREATE TABLE IF NOT EXISTS re_requests (
 trend_id TEXT NOT NULL,
 base_revision INTEGER NOT NULL CHECK(base_revision > 0),
 entered_top30_at TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'requested' CHECK(status IN ('requested','applied')),
 requested_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 applied_at TEXT,
 PRIMARY KEY(trend_id, base_revision)
);
CREATE INDEX IF NOT EXISTS ix_v2_re_requests_status ON re_requests(status,requested_at);
