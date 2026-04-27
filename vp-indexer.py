#!/usr/bin/env python3
"""
vp-indexer.py — VP Library Scene Indexer (mCLIP + Gemma4)
==========================================================
ประมวลผลภาพ VP scene:
  1. โหลด scenes.json เพื่อดูรายการฉากและ path ของรูป
  2. (ถ้าไม่ใช่ --skip-tag) ส่งภาพให้ Gemma4 via LM Studio → caption + tags (TH+EN)
  3. Encode ภาพด้วย mCLIP multilingual (ViT-B/32) → vector 512d
  4. บันทึก vector + metadata ลง Supabase public.scenes

มีอะไรใหม่กว่าระบบเดิม:
  - mCLIP รองรับ Thai + English ในพื้นที่ vector เดียว (ไม่ต้องแปลภาษา)
  - Encode รูปภาพจริงๆ (ไม่ใช่แค่ text tags)
  - Gemma4 ให้ caption ที่ดีกว่า moondream มาก

วิธีติดตั้ง (ครั้งเดียว):
  pip install sentence-transformers supabase pillow requests python-dotenv

วิธีรัน:
  python vp-indexer.py                  ← index ฉากที่ยังไม่มี mclip_vector
  python vp-indexer.py --force          ← index ใหม่ทั้งหมด
  python vp-indexer.py --scene VP-001   ← index ฉากเดียว
  python vp-indexer.py --skip-tag       ← ข้าม Gemma4 (encode image อย่างเดียว)
  python vp-indexer.py --dry-run        ← ดูผลโดยไม่บันทึก
  python vp-indexer.py --limit 3        ← ทดสอบแค่ 3 ฉากแรก

ไฟล์ที่ต้องมี:
  .env (หรือ vp-indexer.env) ดูตัวอย่างที่ vp-indexer.env.example
"""

import argparse
import base64
import io
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ── ตรวจสอบ dependencies ────────────────────────────────────────────
missing = []
for pkg, install in [
    ("sentence_transformers", "sentence-transformers"),
    ("supabase",              "supabase"),
    ("PIL",                   "pillow"),
    ("requests",              "requests"),
    ("dotenv",                "python-dotenv"),
]:
    try:
        __import__(pkg)
    except ImportError:
        missing.append(install)

if missing:
    print("❌ ยังไม่ได้ติดตั้ง:\n")
    print(f"   pip install {' '.join(missing)}\n")
    sys.exit(1)

import requests
from PIL import Image
from dotenv import load_dotenv
from supabase import create_client
from sentence_transformers import SentenceTransformer

# ── โหลด .env ────────────────────────────────────────────────────────
_env_file = Path(__file__).parent / "vp-indexer.env"
if not _env_file.exists():
    _env_file = Path(__file__).parent / ".env"
load_dotenv(_env_file)

# ── Config ───────────────────────────────────────────────────────────
SUPABASE_URL    = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY    = os.environ.get("SUPABASE_KEY", "")   # service_role key

# LM Studio — รองรับทั้ง localhost และ Cloudflare Tunnel URL
# ถ้าใช้ Cloudflare: cloudflared tunnel --url http://localhost:1234
# แล้วใส่ URL ที่ได้ใน LM_STUDIO_URL เช่น https://xxxx.trycloudflare.com/v1
LM_STUDIO_URL   = os.environ.get("LM_STUDIO_URL",   "http://localhost:1234/v1")
LM_STUDIO_MODEL = os.environ.get("LM_STUDIO_MODEL", "")  # ว่าง = auto-detect
LM_STUDIO_KEY   = os.environ.get("LM_STUDIO_KEY",   "")  # API Key (LM Studio → Developer → API Tokens)

EMBED_MODEL     = os.environ.get("EMBED_MODEL", "clip-ViT-B-32-multilingual-v1")

BASE_PATH = Path(__file__).parent   # โฟลเดอร์ VP_Library
SCENES_JSON = BASE_PATH / "_database" / "scenes.json"

# ── Vision Prompt ────────────────────────────────────────────────────
VISION_PROMPT = """Analyze this TV broadcast background scene image. Respond ONLY with valid JSON, no explanation, no markdown.

{
  "caption_en": "One precise English sentence: setting, lighting, mood, and visual style",
  "caption_th": "ประโยคภาษาไทยบรรยายฉาก สถานที่ แสง บรรยากาศ และสไตล์",
  "tags": ["tag1", "tag2", "tag3", "tag4", "tag5"],
  "objects": ["object1", "object2", "object3"]
}

Tag guidelines (5-10 tags, English only):
- Setting: indoor, outdoor, industrial, sci-fi, studio, urban, nature, underground
- Lighting: dramatic, soft, backlit, golden-hour, cool, warm, dark, bright
- Mood: tense, calm, mysterious, energetic, authoritative, nostalgic, futuristic
- Style: cinematic, documentary, editorial, minimal, high-contrast
- Color palette: cool-blue, warm-amber, monochrome, vibrant, muted

Object guidelines (key visible elements, simple English nouns)"""


# ── Helper: ย่อภาพก่อนส่ง Vision model ─────────────────────────────
def resize_for_vision(image_bytes: bytes, max_px: int = 1024) -> bytes:
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = img.size
    if max(w, h) > max_px:
        scale = max_px / max(w, h)
        img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return buf.getvalue()


# ── Helper: เช็ค LM Studio ──────────────────────────────────────────
def check_lm_studio() -> str | None:
    try:
        r = requests.get(f"{LM_STUDIO_URL}/models", timeout=8, headers=_lm_headers())
        r.raise_for_status()
        models = r.json().get("data", [])
        if not models:
            print("⚠️  LM Studio เปิดอยู่ แต่ยังไม่ได้โหลด model")
            print("   ไปที่ LM Studio → Local Server → โหลด Gemma 4 Vision ก่อน\n")
            return None
        model_id = LM_STUDIO_MODEL or models[0]["id"]
        tunnel = "(Cloudflare Tunnel)" if "trycloudflare" in LM_STUDIO_URL else "(localhost)"
        print(f"✅ LM Studio พร้อม {tunnel} — model: {model_id}")
        return model_id
    except requests.ConnectionError:
        print(f"❌ เชื่อมต่อ LM Studio ไม่ได้ที่ {LM_STUDIO_URL}")
        if "localhost" in LM_STUDIO_URL:
            print("   ตรวจสอบว่า LM Studio เปิด Local Server อยู่ (สีเขียว)")
            print("   💡 หรือใช้ Cloudflare Tunnel: cloudflared tunnel --url http://localhost:1234\n")
        else:
            print("   ลอง re-run Cloudflare Tunnel — URL เปลี่ยนทุกครั้งที่ Terminal ใหม่\n")
        return None
    except Exception as e:
        print(f"❌ LM Studio error: {e}\n")
        return None


# ── Helper: เรียก Gemma4 Vision ─────────────────────────────────────
def _lm_headers() -> dict:
    """สร้าง headers สำหรับ LM Studio — ใส่ Bearer token ถ้ามี API Key"""
    h = {"Content-Type": "application/json"}
    if LM_STUDIO_KEY:
        h["Authorization"] = f"Bearer {LM_STUDIO_KEY}"
    return h


def call_gemma4_vision(image_bytes: bytes, model_id: str) -> dict | None:
    resized  = resize_for_vision(image_bytes)
    b64      = base64.b64encode(resized).decode("utf-8")
    data_uri = f"data:image/jpeg;base64,{b64}"

    payload = {
        "model": model_id,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": data_uri}},
                {"type": "text",      "text": VISION_PROMPT}
            ]
        }],
        "temperature": 0.1,
        "max_tokens": 500,
        "stream": False
    }

    try:
        r = requests.post(
            f"{LM_STUDIO_URL}/chat/completions",
            json=payload, timeout=180,
            headers=_lm_headers()
        )
        r.raise_for_status()
        raw = r.json()["choices"][0]["message"]["content"].strip()

        # แกะ JSON ออกจาก ```json ... ```
        if "```" in raw:
            for part in raw.split("```"):
                part = part.strip()
                if part.startswith("json"):
                    part = part[4:]
                if part.strip().startswith("{"):
                    raw = part.strip()
                    break

        return json.loads(raw)

    except json.JSONDecodeError:
        print(f"    ⚠️  Gemma ตอบไม่ใช่ JSON: {raw[:80]}…")
        return None
    except requests.Timeout:
        print("    ⚠️  Timeout (Gemma ใช้เวลานานเกิน 3 นาที)")
        return None
    except Exception as e:
        print(f"    ⚠️  LM Studio error: {e}")
        return None


# ── Helper: หา image path จาก scenes.json ───────────────────────────
def find_image_path(scene: dict) -> Path | None:
    """หาไฟล์ภาพ — ลอง filepath จาก scenes.json ก่อน แล้ว fallback ค้นหาตาม id"""
    # 1. ลอง filepath ใน scenes.json
    fp = scene.get("filepath", "")
    if fp:
        p = BASE_PATH / fp
        if p.exists():
            return p

    # 2. ค้นหาด้วย id (VP-001, VP-002 ...)
    sid = scene["id"]
    for ext in [".webp", ".png", ".jpg", ".jpeg"]:
        matches = list(BASE_PATH.rglob(f"{sid}*{ext}"))
        if matches:
            # ไม่เอาไฟล์ thumbnail
            non_thumb = [m for m in matches if "_thumb" not in m.name]
            if non_thumb:
                return non_thumb[0]

    return None


# ════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(
        description="VP Library Scene Indexer — mCLIP + Gemma4"
    )
    parser.add_argument("--force",     action="store_true", help="index ใหม่ทั้งหมด (ไม่ skip)")
    parser.add_argument("--skip-tag",  action="store_true", help="ข้าม Gemma4 (encode image อย่างเดียว)")
    parser.add_argument("--scene",     type=str, default="",  help="index ฉากเดียว เช่น VP-001")
    parser.add_argument("--limit",     type=int, default=0,   help="จำกัดจำนวน (0=ทั้งหมด)")
    parser.add_argument("--dry-run",   action="store_true", help="แสดงผลเฉยๆ ไม่บันทึก")
    args = parser.parse_args()

    print("\n" + "═" * 62)
    print("  VP Library — Scene Indexer  (mCLIP + Gemma4 Vision)")
    print("═" * 62)

    # ── ตรวจสอบ config ─────────────────────────────────────────────
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("\n❌ ยังไม่ได้ตั้งค่า SUPABASE_URL / SUPABASE_KEY")
        print("   สร้างไฟล์ vp-indexer.env จาก vp-indexer.env.example\n")
        sys.exit(1)

    # ── โหลด scenes.json ──────────────────────────────────────────
    if not SCENES_JSON.exists():
        print(f"\n❌ ไม่พบ {SCENES_JSON}\n")
        sys.exit(1)

    with open(SCENES_JSON, encoding="utf-8") as f:
        db = json.load(f)
    all_scenes = db.get("scenes", [])
    print(f"\n📋 scenes.json v{db.get('version','?')} — {len(all_scenes)} ฉากทั้งหมด")

    # ── filter ตาม --scene / --force ──────────────────────────────
    if args.scene:
        scenes = [s for s in all_scenes if s["id"] == args.scene.upper()]
        if not scenes:
            print(f"\n❌ ไม่พบฉาก '{args.scene}' ใน scenes.json\n")
            sys.exit(1)
    elif not args.force:
        # ดึง ids ที่มี mclip_vector แล้วจาก Supabase
        print("\n🔗 เช็ค Supabase ว่าฉากไหนมี mclip_vector แล้ว…")
        try:
            _sb = create_client(SUPABASE_URL, SUPABASE_KEY)
            indexed = _sb.table("scenes").select("id").not_.is_("mclip_vector", "null").execute()
            indexed_ids = {r["id"] for r in (indexed.data or [])}
            scenes = [s for s in all_scenes if s["id"] not in indexed_ids]
            print(f"   {len(indexed_ids)} ฉากมี vector แล้ว → จะ index อีก {len(scenes)} ฉาก")
        except Exception as e:
            print(f"   ⚠️  เช็ค Supabase ไม่ได้: {e} — index ทั้งหมดแทน")
            scenes = list(all_scenes)
    else:
        scenes = list(all_scenes)

    # เฉพาะ status = active
    scenes = [s for s in scenes if (s.get("status", "active") == "active")]

    if args.limit > 0:
        scenes = scenes[:args.limit]

    if not scenes:
        print("\n✅ ทุกฉากมี vector แล้ว — ไม่ต้องทำอะไร\n")
        return

    total = len(scenes)
    print(f"\n📋 จะ index {total} ฉาก")
    if args.dry_run:
        print("⚠️  --dry-run mode: จะไม่บันทึก\n")

    # ── LM Studio (ถ้าไม่ --skip-tag) ────────────────────────────
    model_id = None
    if not args.skip_tag:
        print(f"\n🔍 เช็ค LM Studio ({LM_STUDIO_URL})…")
        model_id = check_lm_studio()
        if not model_id:
            print("   💡 ใช้ --skip-tag เพื่อข้าม Gemma4 และ encode image อย่างเดียว\n")
            sys.exit(1)
        if LM_STUDIO_MODEL:
            model_id = LM_STUDIO_MODEL
    print()

    # ── โหลด mCLIP ────────────────────────────────────────────────
    print(f"📦 โหลด mCLIP model: {EMBED_MODEL}")
    print("   (ครั้งแรกจะ download ~400MB — หลังจากนั้น cache ไว้แล้ว)\n")
    embedder = SentenceTransformer(EMBED_MODEL)
    dim = embedder.get_sentence_embedding_dimension()
    print(f"✅ mCLIP พร้อม (dim={dim})\n")

    # ── เชื่อม Supabase ───────────────────────────────────────────
    print("🔗 เชื่อมต่อ Supabase…")
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)
    print("✅ Supabase พร้อม\n")

    # ── Loop index ────────────────────────────────────────────────
    success = failed = skipped = 0

    for i, scene in enumerate(scenes, 1):
        sid   = scene["id"]
        title = scene.get("title", sid)
        print(f"[{i}/{total}] {sid} — {title[:50]}")

        # 1. หาไฟล์ภาพ
        img_path = find_image_path(scene)
        if not img_path:
            print(f"    ⚠️  ไม่พบไฟล์ภาพ — ข้ามไป\n")
            skipped += 1
            continue

        print(f"    📁 {img_path.relative_to(BASE_PATH)}")

        # 2. โหลดภาพ
        try:
            img_bytes = img_path.read_bytes()
            img_pil   = Image.open(io.BytesIO(img_bytes)).convert("RGB")
        except Exception as e:
            print(f"    ⚠️  โหลดภาพไม่ได้: {e}\n")
            failed += 1
            continue

        # 3. Gemma4 Vision (optional)
        caption_en = scene.get("mclip_caption", "")
        caption_th = scene.get("mclip_caption_th", "") or scene.get("title_th", "")
        tags       = scene.get("mclip_tags",    []) or scene.get("context_tags", [])
        objects    = scene.get("mclip_objects", [])

        if model_id:
            print(f"    🧠 Gemma4 วิเคราะห์ภาพ…", end=" ", flush=True)
            t0   = time.time()
            meta = call_gemma4_vision(img_bytes, model_id)
            dt   = time.time() - t0

            if meta:
                caption_en = meta.get("caption_en") or meta.get("caption", "")
                caption_th = meta.get("caption_th", caption_th)
                tags       = meta.get("tags",    tags)
                objects    = meta.get("objects", objects)
                print(f"✓ ({dt:.1f}s)")
                print(f"    📝 EN: {caption_en[:65]}")
                if caption_th:
                    print(f"    📝 TH: {caption_th[:65]}")
                print(f"    🏷  {tags[:5]}")
            else:
                print(f"    ⚠️  Gemma ตอบไม่ถูกต้อง — ใช้ข้อมูลเดิม")

        # 4. mCLIP encode image → 512d vector
        print(f"    🔢 mCLIP encode image…", end=" ", flush=True)
        try:
            t0     = time.time()
            vector = embedder.encode(img_pil, normalize_embeddings=True).tolist()
            dt     = time.time() - t0
            print(f"✓ (dim={len(vector)}, {dt:.2f}s)")
        except Exception as e:
            print(f"\n    ⚠️  mCLIP encode ไม่ได้: {e}\n")
            failed += 1
            continue

        # 5. บันทึก Supabase
        if not args.dry_run:
            payload = {
                "mclip_vector":     vector,
                "mclip_caption":    caption_en,
                "mclip_caption_th": caption_th,
                "mclip_tags":       tags,
                "mclip_objects":    objects,
                "mclip_indexed_at": datetime.now(timezone.utc).isoformat(),
            }
            try:
                sb.table("scenes").update(payload).eq("id", sid).execute()
                print(f"    💾 บันทึก Supabase ✓")
            except Exception as e:
                print(f"    ❌ บันทึก Supabase ล้มเหลว: {e}")
                failed += 1
                continue
        else:
            print(f"    🔍 dry-run — ข้ามการบันทึก")

        success += 1
        print()

    # ── สรุป ─────────────────────────────────────────────────────
    print("═" * 62)
    print(f"✅  สำเร็จ: {success}/{total} ฉาก"
          + (f"  |  ข้าม: {skipped}" if skipped else "")
          + (f"  |  ล้มเหลว: {failed}" if failed else ""))
    if args.dry_run:
        print("ℹ️   dry-run — ไม่มีการบันทึกข้อมูล")
    if success > 0 and not args.dry_run:
        print("\n👉 รัน vp-search-server.py เพื่อทดสอบค้นหา")
    print("═" * 62 + "\n")


if __name__ == "__main__":
    main()
