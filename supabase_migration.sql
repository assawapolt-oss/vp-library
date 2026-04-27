-- ═══════════════════════════════════════════════════════════════════
-- VP Library — Supabase Migration Script
-- วิธีใช้: Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- ═══════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. ADD MISSING COLUMNS TO SCENES TABLE
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.scenes
  ADD COLUMN IF NOT EXISTS sort_order        integer   DEFAULT 0,
  ADD COLUMN IF NOT EXISTS video_url         text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS presenter_image_url text    DEFAULT '',
  ADD COLUMN IF NOT EXISTS motion_bg_url     text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS world             text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS energy            text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS context_tags      text[]    DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS show_ids          text[]    DEFAULT '{}',
  -- Canvas / Lighting Blueprint fields
  ADD COLUMN IF NOT EXISTS key_light_dir     text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS key_light_type    text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS fill_light        text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS back_light        text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS lighting_ratio    text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS presenter_zone    text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS camera_setup      text      DEFAULT '',
  ADD COLUMN IF NOT EXISTS canvas_notes      text      DEFAULT '',
  -- Lighting equipment slots (FK to equipment table below)
  ADD COLUMN IF NOT EXISTS key_light_equip_id   text  DEFAULT '',
  ADD COLUMN IF NOT EXISTS fill_light_equip_id  text  DEFAULT '',
  ADD COLUMN IF NOT EXISTS back_light_equip_id  text  DEFAULT '';

-- ──────────────────────────────────────────────────────────────────
-- 2. EQUIPMENT TABLE (สำหรับ Lighting Blueprint)
-- ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.equipment (
  id          text PRIMARY KEY,          -- e.g. EQ-001
  name        text NOT NULL DEFAULT '',  -- "Aputure 600d Pro"
  brand       text DEFAULT '',           -- "Aputure"
  model       text DEFAULT '',           -- "600d Pro"
  category    text DEFAULT '',           -- key_light | fill_light | back_light | special | other
  image_url   text DEFAULT '',           -- Supabase Storage URL (webp)
  notes       text DEFAULT '',
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

-- Row Level Security — อ่านได้ทุกคน, เขียนได้ (anon key ก็ได้เพราะ GitHub Pages ใช้ anon)
ALTER TABLE public.equipment ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='equipment' AND policyname='Public read equipment'
  ) THEN
    CREATE POLICY "Public read equipment" ON public.equipment FOR SELECT USING (true);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='equipment' AND policyname='Public write equipment'
  ) THEN
    CREATE POLICY "Public write equipment" ON public.equipment FOR ALL USING (true);
  END IF;
END $$;

-- ──────────────────────────────────────────────────────────────────
-- 3. SHOWS TABLE — add sort_order column for drag-to-reorder
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.shows
  ADD COLUMN IF NOT EXISTS sort_order integer DEFAULT 0;

-- ──────────────────────────────────────────────────────────────────
-- 4. SERVICE REQUESTS TABLE — add time_slot for morning/afternoon
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.service_requests
  ADD COLUMN IF NOT EXISTS time_slot text DEFAULT '';

-- ──────────────────────────────────────────────────────────────────
-- 5. LAYER 4 POSTURE + PRODUCTION FORMAT (v2 — 2026-03-31)
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.scenes
  ADD COLUMN IF NOT EXISTS posture     text DEFAULT '',   -- 'sitting' | 'standing' | 'special'
  ADD COLUMN IF NOT EXISTS prod_format text DEFAULT '';   -- 'solo-host' | 'news-desk' | 'interview' | 'round-table' | 'vertical'

-- เพิ่ม equipment slots เพิ่มเติม (rim + ambient)
ALTER TABLE public.scenes
  ADD COLUMN IF NOT EXISTS rim_l_equip_id   text DEFAULT '',
  ADD COLUMN IF NOT EXISTS rim_r_equip_id   text DEFAULT '',
  ADD COLUMN IF NOT EXISTS ambient_equip_id text DEFAULT '';

-- ──────────────────────────────────────────────────────────────────
-- 6. STATUS + TITLE_TH columns (v3 — 2026-04-01)
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.scenes
  ADD COLUMN IF NOT EXISTS status    text DEFAULT 'active',  -- 'active' | 'inactive'
  ADD COLUMN IF NOT EXISTS title_th  text DEFAULT '';        -- ชื่อฉากภาษาไทย

-- Backfill: any legacy draft/archived → inactive
UPDATE public.scenes SET status = 'inactive' WHERE status IN ('draft','archived');

-- ──────────────────────────────────────────────────────────────────
-- 7. USER AVATARS (v3 — 2026-04-01)
-- ──────────────────────────────────────────────────────────────────
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS avatar_url text DEFAULT '';

-- ──────────────────────────────────────────────────────────────────
-- 8. VERIFY — ดู columns ที่มีใน scenes ตอนนี้
-- ──────────────────────────────────────────────────────────────────
SELECT column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'scenes'
ORDER BY ordinal_position;

-- ──────────────────────────────────────────────────────────────────
-- 9. VERIFY — service_requests columns
-- ──────────────────────────────────────────────────────────────────
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'service_requests'
ORDER BY ordinal_position;

-- ══════════════════════════════════════════════════════════════════
-- 10. FIX RLS: collections + service_requests (v4 — 2026-04-03)
--     ❗ สำคัญมาก: ทำให้ข้อมูล Collections และ Service Requests กลับมา
--     วิธีใช้: Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- ══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- collections table — สร้างถ้ายังไม่มี + เปิด RLS ให้ถูกต้อง
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.collections (
  id          text PRIMARY KEY DEFAULT ('COL-' || extract(epoch from now())::bigint::text),
  name        text NOT NULL DEFAULT '',
  emoji       text DEFAULT '🗂',
  season      text DEFAULT '',
  year        text DEFAULT '',
  description text DEFAULT '',
  color       text DEFAULT '#CC2229',
  cover_url   text DEFAULT '',
  scene_ids   text[] DEFAULT '{}',
  sort_order  integer DEFAULT 0,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

ALTER TABLE public.collections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read collections"  ON public.collections;
DROP POLICY IF EXISTS "Public write collections" ON public.collections;
DROP POLICY IF EXISTS "Allow all collections"    ON public.collections;

-- อ่านได้ทุกคน (anon + authenticated)
CREATE POLICY "Public read collections"
  ON public.collections FOR SELECT USING (true);

-- เขียน/แก้ไข/ลบได้ผ่าน anon key (admin page ใช้ anon key)
CREATE POLICY "Public write collections"
  ON public.collections FOR ALL USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────
-- service_requests table — เปิด RLS ให้ถูกต้อง
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE public.service_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read service_requests"  ON public.service_requests;
DROP POLICY IF EXISTS "Public write service_requests" ON public.service_requests;
DROP POLICY IF EXISTS "Allow all service_requests"    ON public.service_requests;

-- อ่านได้ทุกคน
CREATE POLICY "Public read service_requests"
  ON public.service_requests FOR SELECT USING (true);

-- เขียน/แก้ไข/ลบได้ผ่าน anon key
CREATE POLICY "Public write service_requests"
  ON public.service_requests FOR ALL USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────
-- VERIFY — ตรวจสอบ policies ที่สร้างแล้ว
-- ─────────────────────────────────────────────────────────────────
SELECT tablename, policyname, cmd
FROM   pg_policies
WHERE  tablename IN ('collections', 'service_requests')
ORDER BY tablename, policyname;

-- ══════════════════════════════════════════════════════════════════
-- 11. SET DEFAULT POSTURE + FORMAT for all existing scenes (v5 — 2026-04-03)
--     ตั้งค่า default ให้ฉากเก่าทุกฉากที่ยังไม่ได้ตั้งค่า
-- ══════════════════════════════════════════════════════════════════

-- ฉากที่ posture ว่าง → ยืน (standing)
UPDATE public.scenes
SET    posture = 'standing'
WHERE  posture IS NULL OR posture = '';

-- ฉากที่ prod_format ว่าง → พิธีกรเดี่ยว (solo-host)
UPDATE public.scenes
SET    prod_format = 'solo-host'
WHERE  prod_format IS NULL OR prod_format = '';

-- เปลี่ยน DEFAULT ใน column ให้ future rows ได้ค่านี้โดยอัตโนมัติ
ALTER TABLE public.scenes
  ALTER COLUMN posture     SET DEFAULT 'standing',
  ALTER COLUMN prod_format SET DEFAULT 'solo-host';

-- VERIFY
SELECT id, title, posture, prod_format
FROM   public.scenes
ORDER BY id;

-- ══════════════════════════════════════════════════════════════════
-- 12. GRAB REF — ref_images table + storage bucket (v6 — 2026-04-03)
--     ❗ แยกจาก scenes ทั้งหมด ใช้เป็น reference image repository
--
--     วิธีใช้:
--       1. รัน SQL นี้ใน Supabase SQL Editor
--       2. ไปที่ Storage → สร้าง bucket ชื่อ "ref-images" (Public bucket)
--       3. เปิดหน้า vp-grab-ref.html แล้วเริ่ม upload ได้เลย
-- ══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.ref_images (
  id            bigserial   PRIMARY KEY,
  storage_path  text        NOT NULL DEFAULT '',   -- path ใน bucket: refs/{ts}-{rand}.webp
  url           text        NOT NULL DEFAULT '',   -- public URL สำหรับ <img src>
  original_name text        DEFAULT '',            -- ชื่อไฟล์ต้นฉบับก่อน convert
  width         integer     DEFAULT 0,             -- px หลัง resize
  height        integer     DEFAULT 0,             -- px หลัง resize
  file_size_kb  integer     DEFAULT 0,             -- KB ของ webp ที่ upload
  uploaded_by   text        DEFAULT 'anon',        -- vp_user_id จาก localStorage
  created_at    timestamptz DEFAULT now()
);

-- Index เรียงตาม created_at สำหรับ masonry grid (newest first)
CREATE INDEX IF NOT EXISTS ref_images_created_at_idx
  ON public.ref_images (created_at DESC);

-- RLS — อ่านได้ทุกคน เขียน/ลบได้ผ่าน anon key (same pattern as collections)
ALTER TABLE public.ref_images ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read ref_images"  ON public.ref_images;
DROP POLICY IF EXISTS "Public write ref_images" ON public.ref_images;

CREATE POLICY "Public read ref_images"
  ON public.ref_images FOR SELECT USING (true);

CREATE POLICY "Public write ref_images"
  ON public.ref_images FOR ALL USING (true) WITH CHECK (true);

-- VERIFY columns
SELECT column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'ref_images'
ORDER BY ordinal_position;

-- ──────────────────────────────────────────────────────────────────
-- Storage bucket setup (ทำใน Supabase Dashboard > Storage)
-- ──────────────────────────────────────────────────────────────────
-- 1. สร้าง bucket ชื่อ "ref-images"
-- 2. เปิด Public bucket (ให้ URL public ได้)
-- 3. ตั้ง File size limit: 10MB (เพียงพอสำหรับ 1920×1080 WebP)
-- 4. Allowed MIME types: image/webp
-- (ถ้าต้องการ policy ใน SQL ทำได้ แต่ Dashboard ง่ายกว่า)

-- ══════════════════════════════════════════════════════════════════
-- 13. SECURITY FIX — require Supabase Auth for all WRITE operations (v7 — 2026-04-15)
--
--  ❗ สำคัญมาก: เปลี่ยนจาก "ใครก็เขียนได้ด้วย anon key"
--              → "ต้อง login ผ่าน Google OAuth (@thestandard.co) ก่อน"
--
--  หลักการ:
--    • READ  (SELECT)          → ยังคงเปิด public (ค้นหาใช้ anon key ได้)
--    • WRITE (INSERT/UPDATE/DELETE) → ต้องผ่าน auth.role() = 'authenticated'
--                                     (= login ด้วย Supabase Auth / Google OAuth สำเร็จ)
--    • service_requests INSERT → ยังคงเปิด anon ได้ (ฟอร์มส่งคำร้อง public)
--      แต่ UPDATE/DELETE ต้องการ auth
--
--  วิธีใช้:
--    Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- ══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- 13a. scenes — ล็อค write ให้ต้อง auth
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE public.scenes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public write scenes"  ON public.scenes;
DROP POLICY IF EXISTS "Allow all scenes"     ON public.scenes;
DROP POLICY IF EXISTS "Auth write scenes"    ON public.scenes;

-- READ: เปิด public (search ใช้ anon key)
DROP POLICY IF EXISTS "Public read scenes" ON public.scenes;
CREATE POLICY "Public read scenes"
  ON public.scenes FOR SELECT USING (true);

-- WRITE: ต้อง authenticated (Google OAuth login สำเร็จ)
CREATE POLICY "Auth write scenes"
  ON public.scenes FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13b. collections — ล็อค write ให้ต้อง auth
-- ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Public write collections" ON public.collections;
DROP POLICY IF EXISTS "Allow all collections"    ON public.collections;
DROP POLICY IF EXISTS "Auth write collections"   ON public.collections;

CREATE POLICY "Auth write collections"
  ON public.collections FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13c. equipment — ล็อค write ให้ต้อง auth
-- ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Public write equipment" ON public.equipment;
DROP POLICY IF EXISTS "Auth write equipment"   ON public.equipment;

CREATE POLICY "Auth write equipment"
  ON public.equipment FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13d. shows — สร้าง RLS + ล็อค write ให้ต้อง auth
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE public.shows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read shows"  ON public.shows;
DROP POLICY IF EXISTS "Public write shows" ON public.shows;
DROP POLICY IF EXISTS "Allow all shows"    ON public.shows;
DROP POLICY IF EXISTS "Auth write shows"   ON public.shows;

CREATE POLICY "Public read shows"
  ON public.shows FOR SELECT USING (true);

CREATE POLICY "Auth write shows"
  ON public.shows FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13e. ref_images — ล็อค write ให้ต้อง auth (GrabRef ต้อง login ก่อนอัปโหลด)
-- ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Public write ref_images" ON public.ref_images;
DROP POLICY IF EXISTS "Auth write ref_images"   ON public.ref_images;

CREATE POLICY "Auth write ref_images"
  ON public.ref_images FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13f. service_requests — INSERT เปิด anon, UPDATE/DELETE ต้อง auth
-- ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Public write service_requests" ON public.service_requests;
DROP POLICY IF EXISTS "Allow all service_requests"    ON public.service_requests;
DROP POLICY IF EXISTS "Public insert service_requests" ON public.service_requests;
DROP POLICY IF EXISTS "Auth modify service_requests"   ON public.service_requests;
DROP POLICY IF EXISTS "Auth delete service_requests"   ON public.service_requests;

-- ใครก็ส่ง request ได้ (ฟอร์ม public)
CREATE POLICY "Public insert service_requests"
  ON public.service_requests FOR INSERT
  WITH CHECK (true);

-- แก้ไข/ลบต้อง auth (admin เท่านั้น)
CREATE POLICY "Auth modify service_requests"
  ON public.service_requests FOR UPDATE
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Auth delete service_requests"
  ON public.service_requests FOR DELETE
  USING      (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- 13g. users — ล็อค read/write ให้ต้อง auth
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read users"  ON public.users;
DROP POLICY IF EXISTS "Public write users" ON public.users;
DROP POLICY IF EXISTS "Auth read users"    ON public.users;
DROP POLICY IF EXISTS "Auth write users"   ON public.users;

CREATE POLICY "Auth read users"
  ON public.users FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "Auth write users"
  ON public.users FOR ALL
  USING      (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ─────────────────────────────────────────────────────────────────
-- VERIFY — ตรวจสอบ policies ทั้งหมดหลังอัปเดต
-- ─────────────────────────────────────────────────────────────────
SELECT tablename, policyname, cmd, qual
FROM   pg_policies
WHERE  tablename IN ('scenes','collections','equipment','shows','ref_images','service_requests','users')
ORDER  BY tablename, cmd, policyname;
