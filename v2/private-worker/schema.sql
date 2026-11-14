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
