-- ═══════════════════════════════════════════════════════════════
-- VP Furniture Refs — Supabase Migration
-- Run this in Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS furniture_refs (
  id              uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  image_url       text        NOT NULL,
  thumb_url       text        DEFAULT '',
  storage_path    text        DEFAULT '',
  source_url      text        DEFAULT '',
  source_title    text        DEFAULT '',
  category        text        NOT NULL DEFAULT 'other',
  style_tags      text[]      DEFAULT '{}',
  notes           text        DEFAULT '',
  used_in_scene_ids text[]    DEFAULT '{}',
  added_by        text        DEFAULT '',
  created_at      timestamptz DEFAULT now()
);

-- RLS
ALTER TABLE furniture_refs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "furniture_refs_read"   ON furniture_refs;
DROP POLICY IF EXISTS "furniture_refs_write"  ON furniture_refs;
DROP POLICY IF EXISTS "furniture_refs_delete" ON furniture_refs;

CREATE POLICY "furniture_refs_read"   ON furniture_refs FOR SELECT USING (true);
CREATE POLICY "furniture_refs_write"  ON furniture_refs FOR INSERT WITH CHECK (true);
CREATE POLICY "furniture_refs_update" ON furniture_refs FOR UPDATE USING (true);
CREATE POLICY "furniture_refs_delete" ON furniture_refs FOR DELETE USING (true);

-- Index for fast category filter
CREATE INDEX IF NOT EXISTS furniture_refs_category_idx ON furniture_refs (category);
CREATE INDEX IF NOT EXISTS furniture_refs_created_idx  ON furniture_refs (created_at DESC);

-- Storage bucket (run separately if needed)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('furniture-refs', 'furniture-refs', true)
-- ON CONFLICT DO NOTHING;
