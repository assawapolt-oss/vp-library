-- ══════════════════════════════════════════════════════════════════
-- FurnitureREF — Cutout (background-removed) version migration
-- รันใน Supabase SQL Editor หลังจาก clip migration
-- ══════════════════════════════════════════════════════════════════

-- เก็บภาพต้นฉบับ (image_url) ไว้เหมือนเดิม
-- เพิ่ม "cutout" version ที่ background ถูกลบแล้ว — เก็บเป็น PNG transparent
ALTER TABLE furniture_refs
  ADD COLUMN IF NOT EXISTS cutout_url        text        DEFAULT '',
  ADD COLUMN IF NOT EXISTS cutout_path       text        DEFAULT '',
  ADD COLUMN IF NOT EXISTS cutout_indexed_at timestamptz;

-- index ใช้กรองรายการที่มี cutout เพื่อโชว์ใน UI
CREATE INDEX IF NOT EXISTS furniture_refs_has_cutout_idx
  ON furniture_refs ((cutout_url <> ''));

-- ══ เสร็จแล้ว ══
-- หลังจากรัน SQL นี้ admin จะเห็นปุ่ม "Cut Object" ใน detail modal
-- กดแล้วระบบจะลบ background ใน browser (ไม่ต้องส่งภาพไป server)
-- บันทึกผลลัพธ์เป็น PNG transparent กลับมาที่ row เดิม
