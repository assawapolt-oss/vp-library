# VP Library — คู่มือระบบฉบับสมบูรณ์

> อัปเดตล่าสุด: เมษายน 2569 (v7 — Security + Auto-Embed + Video Preview)
> สถาปัตยกรรมปัจจุบัน: **Google Colab embed + Browser CLIP search + NMT Thai→English**

---

## ภาพรวมระบบ

VP Library เป็นระบบจัดการและค้นหาภาพฉาก (B-roll) สำหรับทีม THE STANDARD ประกอบด้วย 3 หน้าหลัก:

| หน้า | ไฟล์ | หน้าที่ |
|------|-------|---------|
| Admin | `vp-admin.html` | จัดการฉาก, อัปโหลดภาพ, แก้ไข tags |
| Search | `vp-search.html` | ค้นหาภาพด้วย AI Semantic Search |
| GrabRef | `vp-grab-ref.html` | เก็บ Reference images + ค้นหาด้วย CLIP |

**Database:** Supabase (PostgreSQL + pgvector)  
**Storage:** Supabase Storage  
**Hosting:** GitHub Pages (static files, ไม่ต้องมี server)

---

## สถาปัตยกรรม CLIP Semantic Search

### หลักการทำงาน

```
ภาพ (JPEG/WebP)
    ↓  [Google Colab — รันครั้งเดียว]
CLIP ViT-B/32 (image encoder)
    ↓
vector[512] → บันทึกใน Supabase (mclip_vector)

---

User พิมพ์ query (ไทย หรือ English)
    ↓  [Browser — real-time]
opus-mt-th-en (NMT) → แปลเป็น English
    ↓
CLIP ViT-B/32 (text encoder) → vector[512]
    ↓
pgvector cosine similarity → ดึงฉากที่ใกล้ที่สุด
```

### โมเดลที่ใช้

| โมเดล | ขนาด | หน้าที่ | โหลดที่ไหน |
|-------|------|---------|------------|
| `openai/clip-vit-base-patch32` | ~25MB (quantized) | Text encoder (query → vector) | Browser (transformers.js) |
| `openai/clip-vit-base-patch32` | ~600MB | Image encoder (ภาพ → vector) | Google Colab (Python) |
| `Xenova/opus-mt-th-en` | ~50MB (quantized) | Thai → English NMT | Browser (transformers.js) |

> **สำคัญ:** Image encoder และ Text encoder ใช้ model เดียวกัน (`clip-vit-base-patch32`) — vectors จึงเปรียบเทียบกันได้

---

## ขั้นตอนการ Embed ภาพ (Google Colab)

### เมื่อไหรต้องรัน Colab?

- เพิ่มฉากใหม่ใน vp-admin.html แล้วอัปโหลดภาพ
- ต้องการ index ภาพใหม่เพื่อให้ค้นหาได้

### วิธีรัน

1. เปิดไฟล์ `vp-embed-colab.ipynb` ใน [Google Colab](https://colab.research.google.com)
   - ลาก .ipynb ไปวางใน Colab หรือ Upload
   - หรือ เปิดจาก GitHub ถ้า repo เป็น public

2. **Cell 2 — ใส่ Supabase Service Key:**
   ```python
   SUPABASE_SERVICE_KEY = 'eyJhbGciOi...'  # ← ใส่ key จริงตรงนี้
   ```
   - หา key ได้ที่: **Supabase Dashboard → Settings → API → Secret keys** (กด 👁 เพื่อเปิดดู)
   - ใช้ **Service Role Key** (ไม่ใช่ anon key) — มีสิทธิ์ write

3. **Runtime → Run all** (Ctrl+F9)

4. รอ ~5–10 นาที (โหลดโมเดลครั้งแรก ~2 นาที, embed ภาพต่อฉาก ~2-3 วินาที)

5. ดูผลใน Cell 6 — ควรเห็น `✅ มี vector: X ฉาก`

### Cell structure ของ Notebook

```
Cell 1: pip install (transformers torch pillow requests supabase)
Cell 2: ⚙️ CONFIG — ใส่ SUPABASE_SERVICE_KEY ที่นี่
Cell 3: โหลด CLIP model + ฟังก์ชัน encode_image()
Cell 4: ดึงรายการฉากจาก Supabase (ข้ามที่ embed แล้วถ้า SKIP_ALREADY_INDEXED=True)
Cell 5: Embed loop → อัปเดต mclip_vector + mclip_indexed_at
Cell 6: (Optional) ตรวจสอบผลลัพธ์
```

### SKIP_ALREADY_INDEXED

```python
SKIP_ALREADY_INDEXED = True   # ข้ามฉากที่มี mclip_indexed_at แล้ว (แนะนำ)
SKIP_ALREADY_INDEXED = False  # Re-embed ทุกฉาก (ใช้เมื่อเปลี่ยน model)
```

---

## Supabase Database Schema

### ตาราง `scenes` (VP Library)

```sql
id               TEXT PRIMARY KEY     -- e.g. "VP-001"
title            TEXT
description      TEXT
image_url        TEXT                 -- Public URL ใน Supabase Storage
mclip_vector     vector(512)          -- CLIP image embedding
mclip_indexed_at TIMESTAMPTZ          -- วันที่ embed ล่าสุด
topics           TEXT[]
editorial_fit    TEXT[]
sort_order       INT
-- ... fields อื่นๆ
```

### Index และ RPC Function

```sql
-- HNSW index สำหรับ fast cosine similarity search
CREATE INDEX scenes_mclip_hnsw ON scenes
  USING hnsw (mclip_vector vector_cosine_ops)
  WITH (m=16, ef_construction=64);

-- RPC function สำหรับ vector search
CREATE OR REPLACE FUNCTION match_scenes_mclip(
  query_vector   vector(512),
  match_count    INT,
  match_threshold FLOAT
)
RETURNS TABLE (id TEXT, similarity FLOAT)
LANGUAGE sql STABLE AS $$
  SELECT id, 1 - (mclip_vector <=> query_vector) AS similarity
  FROM   scenes
  WHERE  mclip_vector IS NOT NULL
    AND  1 - (mclip_vector <=> query_vector) >= match_threshold
  ORDER  BY mclip_vector <=> query_vector
  LIMIT  match_count;
$$;
```

### ตาราง `ref_images` (GrabRef)

```sql
id               UUID PRIMARY KEY
title            TEXT
image_url        TEXT
mclip_vector     vector(512)          -- CLIP image embedding
mclip_indexed_at TIMESTAMPTZ
-- ... fields อื่นๆ
```

---

## การทำงานของ Search (Browser)

### ลำดับการโหลดเมื่อเปิดหน้า vp-search.html

1. HTML โหลด → Supabase JS init
2. `<script type="module">` เริ่มโหลด 2 โมเดลพร้อมกัน (parallel):
   - **CLIP text encoder** (~25MB, quantized) — ใช้ encode query เป็น vector
   - **opus-mt-th-en** (~50MB, quantized) — ใช้แปลไทย → English
3. Browser cache models หลังจากโหลดครั้งแรก — ครั้งถัดไปเร็วมาก
4. Status bar แสดง progress

### เมื่อ User ค้นหา

```
User พิมพ์ query
    ↓
_translateToEnglish(query)
    ├── ถ้า NMT พร้อม → opus-mt-th-en translate
    └── ถ้า NMT ยังโหลด → keyword fallback map
    ↓
_encodeTextLocal(translated)  ← CLIP text encoder
    ↓
_callSearchAPI(vector, limit=100)
    ↓
Supabase RPC: match_scenes_mclip(query_vector, 100, 0.05)
    ↓
ผสม CLIP score + Tag score → จัดเรียง
    ↓
แสดง Top 5 ผลลัพธ์
```

### Threshold

- `match_threshold: 0.05` — ค่อนข้าง low → แสดงผลได้แม้ query ไม่ตรง 100%
- ปรับใน `_callSearchAPI()` ถ้าต้องการ strict/loose มากขึ้น

---

## การ Setup ระบบใหม่ (จาก Zero)

### 1. Supabase Setup

1. สร้าง Project ใน [supabase.com](https://supabase.com)
2. เปิด extension pgvector:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   ```
3. สร้าง table + index + function ตาม schema ด้านบน
4. สร้าง Storage bucket: `vp-images` (public)
5. คัดลอก API keys: Settings → API

### 2. แก้ไข Config ในไฟล์ HTML

ใน `vp-search.html`, `vp-admin.html`, `vp-grab-ref.html`:
```javascript
const SUPABASE_URL  = 'https://xxxx.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOi...';  // anon/public key
```

### 3. อัปโหลดภาพและ Tag

1. เปิด `vp-admin.html`
2. เพิ่มฉากใหม่ → อัปโหลดภาพ → กรอก tags
3. บันทึก

### 4. Embed ภาพ

1. เปิด `vp-embed-colab.ipynb` ใน Google Colab
2. ใส่ Service Role Key ใน Cell 2
3. Runtime → Run all
4. รอจนเสร็จ

### 5. ทดสอบ Search

1. เปิด `vp-search.html`
2. รอสักครู่ให้ models โหลด (ดู status bar มุมล่าง)
3. พิมพ์ query ไทยหรือ English → กด 🔍

---

## Troubleshooting

### ค้นหาไม่เจอผลลัพธ์

1. ตรวจว่า Colab embed เสร็จหรือยัง — ดูใน Cell 6 ว่า `mclip_vector IS NOT NULL`
2. ลอง query สั้นๆ เช่น "factory" หรือ "night city"
3. ตรวจ Console browser — ดู `[NMT]` หรือ `[KW fallback]` log

### CLIP model โหลดไม่สำเร็จ

- ตรวจ internet connection
- ลอง hard refresh (Ctrl+Shift+R) เพื่อล้าง cache
- ดู error ใน browser console

### Colab Error: `vision_model` attribute not found

- ตรวจว่าใช้ `transformers` version ล่าสุด (`pip install -U transformers`)
- Colab v4 ใช้ `vision_model().pooler_output` → `visual_projection()` — stable กว่า `get_image_features()`

### Search ช้ามาก

- ครั้งแรกที่เปิดหน้า: CLIP (~25MB) + NMT (~50MB) โหลดจาก CDN ~30-60 วินาที
- ครั้งถัดไป: browser cache → เร็วมาก (~1-2 วินาที)
- Status bar มุมล่างซ้ายแสดง progress การโหลด

---

## ไฟล์ในระบบ

```
VP_Library/
├── vp-search.html                        ← หน้าค้นหา (ใช้งานหลัก) + Video Hover Preview
├── vp-admin.html                         ← จัดการ/เพิ่มฉาก
├── vp-grab-ref.html                      ← เก็บ Reference + CLIP search
├── vp-embed-colab.ipynb                  ← Google Colab Notebook สำหรับ embed ภาพ
├── supabase_migration.sql                ← SQL migrations ทั้งหมด (v1–v7)
├── supabase/functions/auto-embed/
│   └── index.ts                          ← Edge Function: auto-embed เมื่ออัปโหลดภาพใหม่
└── VP_SYSTEM_INSTRUCTIONS.md             ← ไฟล์นี้
```

---

## Security Architecture (v7 — 2026-04-15)

### RLS Policy ปัจจุบัน

| Table | SELECT | INSERT | UPDATE/DELETE |
|-------|--------|--------|---------------|
| `scenes` | public | auth only | auth only |
| `collections` | public | auth only | auth only |
| `equipment` | public | auth only | auth only |
| `shows` | public | auth only | auth only |
| `ref_images` | public | auth only | auth only |
| `service_requests` | public | **anon OK** | auth only |
| `users` | auth only | auth only | auth only |

**"auth only"** = ต้อง login ผ่าน Google OAuth (@thestandard.co) ก่อน
— Supabase Auth ออก JWT พร้อม `role = 'authenticated'`
— Policy ตรวจ `auth.role() = 'authenticated'`

### วิธี Apply Security Fix
รัน section **13** ใน `supabase_migration.sql` ผ่าน Supabase SQL Editor

---

## Auto-Embed Edge Function (v7)

### หลักการทำงาน

```
Admin อัปโหลดภาพใหม่ใน vp-admin.html
    ↓
Supabase Database Webhook (INSERT/UPDATE on scenes)
    ↓
Edge Function: supabase/functions/auto-embed/index.ts
    ↓  (download image → HuggingFace CLIP API)
mclip_vector + mclip_indexed_at อัปเดตอัตโนมัติ
    ↓
ค้นหาได้เลยใน vp-search.html
```

ไม่ต้องเปิด Google Colab อีกต่อไปสำหรับภาพใหม่แต่ละรูป

### วิธี Deploy

**1. ติดตั้ง Supabase CLI:**
```bash
npm install -g supabase
supabase login
supabase link --project-ref pgaqdqbjyewwckpslyvx
```

**2. ตั้ง Secrets:**
```bash
supabase secrets set HF_TOKEN=hf_xxxxxxxxxxxxxxxx
```
(รับ HF token ฟรีที่ https://huggingface.co/settings/tokens)

**3. Deploy:**
```bash
supabase functions deploy auto-embed --no-verify-jwt
```

**4. สร้าง Database Webhook ใน Supabase Dashboard:**
- Dashboard → Database → Webhooks → Create new webhook
- Name: `auto-embed-on-scene-upsert`
- Table: `scenes`
- Events: `INSERT`, `UPDATE`
- URL: `https://pgaqdqbjyewwckpslyvx.supabase.co/functions/v1/auto-embed`
- HTTP Headers: `{ "Authorization": "Bearer <SUPABASE_ANON_KEY>" }`

**หมายเหตุ:** Google Colab ยังใช้งานได้เสมอสำหรับ re-embed ทั้งหมด (เช่น เปลี่ยน model)

---

## Video Preview on Hover (v7)

### วิธีทำงาน

เมื่อ scene มี `video_url` (YouTube / Vimeo):
- Card จะแสดง badge "▶ Video" มุมล่างขวา
- Hover ค้าง 600ms → โหลด iframe autoplay+muted ซ้อนบนภาพ
- Mouse ออก → หยุดวิดีโอ + ลบ iframe ทันที (ป้องกัน audio ค้าง)

### วิธีเพิ่ม video_url ให้ฉาก
1. เปิด `vp-admin.html`
2. เลือกฉาก → แท็บ "Video / Motion"
3. วาง YouTube URL เช่น `https://www.youtube.com/watch?v=xxxxx`
4. Save

---

## หมายเหตุสำคัญ

- **ไม่ต้องมี Python server** — ทุกอย่างทำงานบน browser + Supabase Edge Functions
- **Auto-Embed ต้องการ HF Token** — รับฟรีที่ huggingface.co, ใส่เป็น Edge Function secret
- **Service Role Key** — ใช้เฉพาะใน Colab / Edge Function เท่านั้น ห้ามใส่ใน HTML
- **Google Colab ยังใช้ได้** — ใช้สำหรับ batch re-embed ทั้งหมดหรือเปลี่ยน model
