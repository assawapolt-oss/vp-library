-- ══════════════════════════════════════════════════════════════════
-- FurnitureREF — CLIP Vector Search Migration
-- รันใน Supabase SQL Editor ก่อนใช้ AI Search ใน vp-furniture-ref.html
-- (ใช้ pattern เดียวกับ ref-images-clip-migration.sql ของ GrabREF)
-- ══════════════════════════════════════════════════════════════════

-- 1. ต้องมี pgvector extension (น่าจะมีอยู่แล้วถ้า GrabREF ทำงานได้)
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. เพิ่ม columns ใน furniture_refs
ALTER TABLE furniture_refs
  ADD COLUMN IF NOT EXISTS mclip_vector     vector(512),
  ADD COLUMN IF NOT EXISTS mclip_indexed_at timestamptz;

-- 3. HNSW index สำหรับ cosine similarity search
CREATE INDEX IF NOT EXISTS furniture_refs_mclip_hnsw
  ON furniture_refs USING hnsw (mclip_vector vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- 4. RPC function สำหรับ vector search
--    เรียกจาก browser: _SB.rpc('match_furniture_mclip', {...})
CREATE OR REPLACE FUNCTION match_furniture_mclip(
  query_vector    vector(512),
  match_count     INT   DEFAULT 100,
  match_threshold FLOAT DEFAULT 0.05
)
RETURNS TABLE (id uuid, similarity FLOAT)
LANGUAGE sql STABLE AS $$
  SELECT
    id,
    1 - (mclip_vector <=> query_vector) AS similarity
  FROM furniture_refs
  WHERE mclip_vector IS NOT NULL
    AND 1 - (mclip_vector <=> query_vector) >= match_threshold
  ORDER BY mclip_vector <=> query_vector
  LIMIT match_count;
$$;

-- ══ เสร็จแล้ว ══
-- หลังจากรัน SQL นี้:
--   1. เปิด vp-furniture-ref.html → AI status dot จะเป็นสีเขียวเมื่อโมเดลโหลดเสร็จ
--   2. Upload ภาพใหม่ → ระบบจะ auto-embed อัตโนมัติใน browser
--   3. รูปเก่า → admin กด "⚡ Batch Embed" ใน toolbar เพื่อ back-fill vector
--   4. ใช้ช่อง AI Search ค้นหาด้วยภาษาไทยหรืออังกฤษได้เลย
