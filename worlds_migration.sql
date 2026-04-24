-- ═══════════════════════════════════════════════════════════════════
-- VP Library — Worlds Table Migration
-- วิธีใช้: Copy ทั้งหมด → วางใน Supabase SQL Editor → กด Run
-- รองรับ 2 ชั้น: Parent World → Sub-world
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. CREATE WORLDS TABLE ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.worlds (
  id          text PRIMARY KEY,                         -- slug เช่น 'industrial'
  label_en    text NOT NULL DEFAULT '',                 -- 'Industrial'
  label_short text NOT NULL DEFAULT '',                 -- 'Industrial' (ใช้ใน tag/chip)
  label_th    text NOT NULL DEFAULT '',                 -- 'อุตสาหกรรม'
  emoji       text NOT NULL DEFAULT '',                 -- '🏭'
  color       text NOT NULL DEFAULT '#E50914',          -- accent hex color
  parent_id   text REFERENCES public.worlds(id) ON DELETE SET NULL,  -- null = top-level
  sort_order  integer NOT NULL DEFAULT 0,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ── 2. RLS ──────────────────────────────────────────────────────────
ALTER TABLE public.worlds ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read worlds"  ON public.worlds;
DROP POLICY IF EXISTS "Auth write worlds"   ON public.worlds;

CREATE POLICY "Public read worlds"
  ON public.worlds FOR SELECT USING (true);

CREATE POLICY "Auth write worlds"
  ON public.worlds FOR ALL USING (auth.role() = 'authenticated');

-- ── 3. SEED — Top-level worlds (parent_id = NULL) ───────────────────
INSERT INTO public.worlds (id, label_en, label_short, label_th, emoji, color, sort_order)
VALUES
  ('industrial',        'Industrial',          'Industrial',   'อุตสาหกรรม',           '🏭', '#F59E0B', 10),
  ('urban-city',        'Urban & City',        'Urban',        'เมืองและชุมชน',          '🌆', '#3B82F6', 20),
  ('interior-office',   'Interior & Office',   'Interior',     'ภายในและออฟฟิศ',          '🏢', '#14B8A6', 30),
  ('commercial-retail', 'Commercial & Retail', 'Commercial',   'การค้าและร้านค้า',         '🛒', '#EC4899', 40),
  ('nature-outdoor',    'Nature & Outdoor',    'Nature',       'ธรรมชาติและกลางแจ้ง',      '🌿', '#10B981', 50),
  ('heritage-culture',  'Heritage & Culture',  'Heritage',     'มรดกและวัฒนธรรม',          '🏛', '#F97316', 60),
  ('scifi-future',      'Sci-Fi & Future',     'Sci-Fi',       'อนาคตและไซ-ไฟ',            '🚀', '#8B5CF6', 70),
  ('transportation',    'Transportation',      'Transport',    'การขนส่ง',               '🚉', '#6366F1', 80),
  ('luxury-premium',    'Luxury & Premium',    'Luxury',       'หรูหราพรีเมียม',           '💎', '#EAB308', 90),
  ('stylized-abstract', 'Stylized & Abstract', 'Stylized',     'สไตล์ล้วนและ Abstract',    '🎭', '#A855F7', 100)
ON CONFLICT (id) DO UPDATE SET
  label_en    = EXCLUDED.label_en,
  label_short = EXCLUDED.label_short,
  label_th    = EXCLUDED.label_th,
  emoji       = EXCLUDED.emoji,
  color       = EXCLUDED.color,
  sort_order  = EXCLUDED.sort_order;

-- ── 4. SEED — Sub-worlds ตัวอย่าง (parent_id = 'industrial') ────────
-- (ลบ comment แล้ว run ถ้าต้องการ seed sub-worlds ด้วย)
/*
INSERT INTO public.worlds (id, label_en, label_short, label_th, emoji, color, parent_id, sort_order)
VALUES
  ('industrial-factory',   'Factory',          'Factory',      'โรงงาน',      '🔩', '#F59E0B', 'industrial', 11),
  ('industrial-warehouse', 'Warehouse',        'Warehouse',    'คลังสินค้า',   '📦', '#D97706', 'industrial', 12),
  ('industrial-refinery',  'Oil Refinery',     'Refinery',     'โรงกลั่น',    '🛢', '#B45309', 'industrial', 13),
  ('urban-skyline',        'City Skyline',     'Skyline',      'สกายไลน์',    '🏙', '#3B82F6', 'urban-city', 21),
  ('urban-street',         'Street',           'Street',       'ถนนเมือง',    '🛣', '#2563EB', 'urban-city', 22)
ON CONFLICT (id) DO NOTHING;
*/

-- ── 5. VERIFY ────────────────────────────────────────────────────────
SELECT id, label_en, label_short, emoji, color, parent_id, sort_order, active
FROM public.worlds
ORDER BY sort_order;
