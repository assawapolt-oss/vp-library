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
