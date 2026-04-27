# REF Search — วิธีติดตั้งและใช้งาน

## ทำอะไรได้บ้าง

พิมพ์ไทยแล้วค้นหาภาพ REF ที่ "ใกล้เคียงที่สุดจริงๆ" ได้เลย เช่น:
- "ปั๊มน้ำมัน" → หาภาพที่มี fuel pump, gas station
- "โรงงานกลางคืน" → หาภาพ industrial night scene
- "dramatic warm lighting" → หาภาพแสงอุ่นดราม่า

ทำไมถึงทำงานได้? Gemma 4 วิเคราะห์ภาพและสร้าง caption + tags เป็นอังกฤษ แล้ว multilingual model ทำให้ "ปั๊มน้ำมัน" กับ "gas station" อยู่ใน vector space เดียวกัน

---

## ขั้นตอนที่ 1 — ทำครั้งเดียว: ติดตั้ง

```bash
pip install supabase sentence-transformers pillow requests python-dotenv fastapi uvicorn
```

---

## ขั้นตอนที่ 2 — ทำครั้งเดียว: ตั้งค่า .env

คัดลอก `.env.example` เป็น `.env`:
```bash
cp .env.example .env
```

แล้วเปิดไฟล์ `.env` และใส่ `SUPABASE_KEY` (service_role key จาก Supabase Dashboard → Project Settings → API → service_role)

---

## ขั้นตอนที่ 3 — ทำครั้งเดียว: รัน SQL Migration ใน Supabase

1. เปิด Supabase Dashboard → SQL Editor
2. คัดลอกเนื้อหาจากไฟล์ `migrate.sql` ทั้งหมด
3. วางใน SQL Editor แล้วกด **Run**
4. ตรวจสอบว่าไม่มี error

---

## ขั้นตอนที่ 4 — ทำครั้งเดียว: Index ภาพทั้งหมด

ตรวจสอบว่า Ollama กำลังทำงาน และมี Gemma 4:
```bash
ollama list   # ดูรายการ models
```

ถ้ายังไม่มี Gemma 4:
```bash
ollama pull gemma4:26b
```

แล้ว index ภาพทั้งหมด (19 ภาพใช้เวลา ~5-10 นาที):
```bash
python indexer.py
```

ดูผลลัพธ์ก่อนบันทึก (dry run):
```bash
python indexer.py --dry-run --limit 2
```

---

## ขั้นตอนที่ 5 — ใช้งาน: เปิด Search UI

```bash
python search_server.py
```

แล้วเปิด browser ที่: **http://localhost:8765**

---

## เพิ่มภาพใหม่

หลังจาก upload ภาพใหม่ผ่าน vp-grab-ref.html แล้ว รัน:
```bash
python indexer.py   # จะ index เฉพาะภาพใหม่ที่ยังไม่มี vector
```

---

## โครงสร้างไฟล์

```
ref-search/
├── migrate.sql         ← รันใน Supabase SQL Editor (ครั้งเดียว)
├── indexer.py          ← วิเคราะห์ภาพด้วย Gemma 4 + สร้าง embeddings
├── search_server.py    ← FastAPI server (รันทุกครั้งที่จะใช้ search)
├── search.html         ← หน้า UI (เปิดผ่าน server อัตโนมัติ)
├── .env.example        ← template config
└── .env                ← config จริง (ห้าม commit ขึ้น git)
```

---

## ทำไมไม่ใช้ CLIP เหมือนเดิม?

| | ระบบเก่า | ระบบใหม่ |
|---|---|---|
| Vision model | moondream (weak) | Gemma 4 26B (SOTA) |
| Embedding | CLIP ViT-B/32 (EN only) | multilingual-e5 (TH+EN) |
| Thai search | ❌ ไม่ได้ | ✅ ได้เลย |
| OCR in image | ❌ ไม่มี | ✅ มี |
| Storage | JSON file | Supabase pgvector |
