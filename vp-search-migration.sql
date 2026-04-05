-- ════════════════════════════════════════════════════════════════════
-- VP Library — mCLIP Vector Search Migration
-- v1.0 — 2026-04-05
--
-- สิ่งที่ migration นี้ทำ:
--   1. เพิ่ม column mclip_vector (512d) + mclip_caption + mclip_tags
--      เข้า public.scenes (ไม่กระทบ column เดิม)
--   2. สร้าง HNSW index สำหรับ fast ANN search
--   3. สร้าง RPC function match_scenes_mclip
--
-- วิธีใช้:
--   Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- ════════════════════════════════════════════════════════════════════

-- ── 1. เปิด pgvector extension ──────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;

-- ── 2. เพิ่ม mCLIP columns เข้า scenes ─────────────────────────────
--    ใช้ IF NOT EXISTS ทั้งหมด → รัน migration ซ้ำได้ปลอดภัย
ALTER TABLE public.scenes
  ADD COLUMN IF NOT EXISTS mclip_vector     vector(512),          -- mCLIP ViT-B/32 multilingual (TH+EN)
  ADD COLUMN IF NOT EXISTS mclip_caption    text        DEFAULT '', -- Gemma4 caption (EN)
  ADD COLUMN IF NOT EXISTS mclip_caption_th text        DEFAULT '', -- Gemma4 caption (TH)
  ADD COLUMN IF NOT EXISTS mclip_tags       text[]      DEFAULT '{}', -- Gemma4 tags
  ADD COLUMN IF NOT EXISTS mclip_objects    text[]      DEFAULT '{}', -- Gemma4 detected objects
  ADD COLUMN IF NOT EXISTS mclip_indexed_at timestamptz;            -- เวลาที่ index ล่าสุด

-- ── 3. HNSW index — เร็วกว่า IVFFlat สำหรับ collection ขนาดเล็ก-กลาง
--    m=16, ef_construction=64 → balance ระหว่าง speed และ recall
CREATE INDEX IF NOT EXISTS scenes_mclip_vector_hnsw
  ON public.scenes
  USING hnsw (mclip_vector vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- ── 4. RPC: match_scenes_mclip ────────────────────────────────────
--    รับ query vector (512d) → คืนฉากที่คล้ายที่สุด พร้อม score
--    เรียกผ่าน: supabase.rpc('match_scenes_mclip', {...})
CREATE OR REPLACE FUNCTION public.match_scenes_mclip(
  query_vector    vector(512),
  match_count     int     DEFAULT 10,
  match_threshold float   DEFAULT 0.05    -- cosine similarity ขั้นต่ำ (0-1)
)
RETURNS TABLE (
  id              text,
  title           text,
  title_th        text,
  filepath        text,
  thumb           text,
  world           text,
  energy          text,
  context_tags    text[],
  posture         text,
  prod_format     text,
  mclip_caption   text,
  mclip_caption_th text,
  mclip_tags      text[],
  similarity      float
)
LANGUAGE sql STABLE
AS $$
  SELECT
    s.id,
    s.title,
    s.title_th,
    s.filepath,
    s.thumb,
    s.world,
    s.energy,
    s.context_tags,
    s.posture,
    s.prod_format,
    s.mclip_caption,
    s.mclip_caption_th,
    s.mclip_tags,
    1 - (s.mclip_vector <=> query_vector) AS similarity
  FROM public.scenes s
  WHERE s.mclip_vector IS NOT NULL
    AND (s.status IS NULL OR s.status = 'active')
    AND 1 - (s.mclip_vector <=> query_vector) >= match_threshold
  ORDER BY s.mclip_vector <=> query_vector
  LIMIT match_count;
$$;

-- Grant execute สำหรับ anon และ authenticated (สำหรับ browser call)
GRANT EXECUTE ON FUNCTION public.match_scenes_mclip TO anon, authenticated;

-- ── 5. VERIFY ────────────────────────────────────────────────────────
--    ตรวจสอบ columns ที่เพิ่มเข้าไป
SELECT
  column_name,
  data_type,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'scenes'
  AND column_name  LIKE 'mclip%'
ORDER BY ordinal_position;
