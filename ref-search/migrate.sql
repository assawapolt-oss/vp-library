-- ═══════════════════════════════════════════════════════════════
-- ref-search/migrate.sql
-- VP Library — Ref Image Semantic Search Migration
-- วิธีใช้: Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- ═══════════════════════════════════════════════════════════════

-- ── 1. เปิด pgvector (ติดตั้งแล้ว แต่ใส่ไว้เผื่อ) ──────────────
CREATE EXTENSION IF NOT EXISTS vector;

-- ── 2. เพิ่ม columns ใหม่เข้า ref_images ────────────────────────
--   ไม่กระทบ columns เดิมเลย (ใช้ IF NOT EXISTS)
ALTER TABLE public.ref_images
  ADD COLUMN IF NOT EXISTS caption       text,
  ADD COLUMN IF NOT EXISTS tags          text[]       DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS objects       text[]       DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS ocr_text      text         DEFAULT '',
  ADD COLUMN IF NOT EXISTS text_vector   vector(768),
  ADD COLUMN IF NOT EXISTS ai_indexed_at timestamptz;

-- ── 3. สร้าง HNSW index (เร็วกว่า IVFFlat สำหรับ < 100k rows) ──
CREATE INDEX IF NOT EXISTS ref_images_text_vector_hnsw
  ON public.ref_images
  USING hnsw (text_vector vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- ── 4. สร้าง SQL search function ─────────────────────────────────
--   เรียกผ่าน Supabase JS: supabase.rpc('search_ref_images', {...})
CREATE OR REPLACE FUNCTION search_ref_images(
  query_vector  vector(768),
  match_count   int     DEFAULT 10,
  min_similarity float  DEFAULT 0.15
)
RETURNS TABLE (
  id            bigint,
  url           text,
  thumb_url     text,
  original_name text,
  caption       text,
  tags          text[],
  ocr_text      text,
  uploaded_by   text,
  created_at    timestamptz,
  similarity    float
)
LANGUAGE sql STABLE
AS $$
  SELECT
    r.id,
    r.url,
    r.thumb_url,
    r.original_name,
    r.caption,
    r.tags,
    r.ocr_text,
    r.uploaded_by,
    r.created_at,
    1 - (r.text_vector <=> query_vector) AS similarity
  FROM public.ref_images r
  WHERE r.text_vector IS NOT NULL
    AND 1 - (r.text_vector <=> query_vector) >= min_similarity
  ORDER BY r.text_vector <=> query_vector
  LIMIT match_count;
$$;

-- ── 5. ยืนยันว่าทุกอย่างพร้อม ──────────────────────────────────
SELECT
  column_name,
  data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'ref_images'
ORDER BY ordinal_position;
