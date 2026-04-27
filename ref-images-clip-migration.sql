-- ══════════════════════════════════════════════════════════════════
-- GrabREF — CLIP Vector Search Migration
-- รันใน Supabase SQL Editor ก่อนใช้ CLIP Search ใน vp-grab-ref.html
-- ══════════════════════════════════════════════════════════════════

-- 1. ต้องมี pgvector extension (น่าจะมีอยู่แล้วถ้า VP Library ทำงานได้)
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. เพิ่ม columns ใน ref_images
ALTER TABLE ref_images
  ADD COLUMN IF NOT EXISTS mclip_vector     vector(512),
  ADD COLUMN IF NOT EXISTS mclip_indexed_at timestamptz;

-- 3. HNSW index สำหรับ cosine similarity search
--    (สร้างหลังจากมี vector แล้ว ถ้าตารางยังว่างสร้างได้เลย)
CREATE INDEX IF NOT EXISTS ref_images_mclip_hnsw
  ON ref_images USING hnsw (mclip_vector vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- 4. RPC function สำหรับ vector search
--    เรียกจาก browser: _SB.rpc('match_refs_mclip', {...})
CREATE OR REPLACE FUNCTION match_refs_mclip(
  query_vector    vector(512),
  match_count     INT          DEFAULT 50,
  match_threshold FLOAT        DEFAULT 0.05
)
RETURNS TABLE (id bigint, similarity FLOAT)
LANGUAGE sql STABLE AS $$
  SELECT
    id,
    1 - (mclip_vector <=> query_vector) AS similarity
  FROM ref_images
  WHERE mclip_vector IS NOT NULL
    AND 1 - (mclip_vector <=> query_vector) >= match_threshold
  ORDER BY mclip_vector <=> query_vector
  LIMIT match_count;
$$;

-- ══ เสร็จแล้ว ══
-- หลังจากรัน SQL นี้:
--   1. เปิด vp-grab-ref.html
--   2. Upload ภาพใหม่ → ระบบจะ embed อัตโนมัติใน browser
--   3. ใช้ AI Search ในหน้า GrabREF ค้นหาด้วย CLIP ได้เลย
