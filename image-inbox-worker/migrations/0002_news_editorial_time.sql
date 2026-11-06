-- Original editorial timestamp, not the later delivery/ingest timestamp.
-- Existing news rows stay NULL and are excluded from the post-cutover inbox.
ALTER TABLE image_candidates ADD COLUMN editorial_at TEXT;
CREATE INDEX IF NOT EXISTS idx_image_candidates_scope
  ON image_candidates(project, editorial_id, revision, editorial_at, created_at DESC);
