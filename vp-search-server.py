#!/usr/bin/env python3
"""
vp-search-server.py — VP Library Search + Embed API
=====================================================
FastAPI server รวม 2 ระบบ:
  1. SEARCH  — text query → mCLIP encode → Supabase pgvector
  2. EMBED   — image URL  → mCLIP encode → Supabase (+ Gemma4 caption/tags ถ้าเปิดอยู่)

Endpoints:
  GET  /         → health + info
  GET  /health   → สถานะ server
  POST /search   → semantic search
  POST /embed    → embed ภาพ 1 ฉาก (admin)
  POST /embed/bulk → embed หลายฉากพร้อมกัน (admin)
  POST /encode   → encode text → vector (debug)

วิธีติดตั้ง:
  pip install fastapi uvicorn sentence-transformers supabase python-dotenv pillow requests

วิธีรัน:
  python vp-search-server.py

ไฟล์ config:
  vp-search-server.env  (คัดลอกจาก vp-search-server.env.example)
"""

import os, io, json, time
from pathlib import Path
from typing import Optional, List
from datetime import datetime, timezone

# ── Load .env ──────────────────────────────────────────────────────
from dotenv import load_dotenv
_env_file = Path(__file__).parent / "vp-search-server.env"
if not _env_file.exists():
    _env_file = Path(__file__).parent / ".env"
load_dotenv(_env_file)

SUPABASE_URL         = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY         = os.environ.get("SUPABASE_KEY", "")          # anon key (read)
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")  # service key (write) — ถ้าไม่มีใช้ anon
EMBED_MODEL          = os.environ.get("EMBED_MODEL", "clip-ViT-B-32-multilingual-v1")
HOST                 = os.environ.get("HOST", "0.0.0.0")
PORT                 = int(os.environ.get("PORT", "8766"))
CORS_ORIGINS         = os.environ.get("CORS_ORIGINS", "*")

# LM Studio / Gemma4 (optional — ใช้เฉพาะตอน embed with_tags=True)
LM_STUDIO_URL   = os.environ.get("LM_STUDIO_URL", "http://localhost:1234/v1")
LM_STUDIO_MODEL = os.environ.get("LM_STUDIO_MODEL", "")   # ชื่อโมเดลใน LM Studio
LM_STUDIO_KEY   = os.environ.get("LM_STUDIO_KEY", "")     # Bearer token

# ── Check dependencies ─────────────────────────────────────────────
import sys
missing = []
for pkg, install in [
    ("fastapi",               "fastapi"),
    ("uvicorn",               "uvicorn"),
    ("sentence_transformers", "sentence-transformers"),
    ("supabase",              "supabase"),
    ("PIL",                   "pillow"),
    ("requests",              "requests"),
]:
    try:
        __import__(pkg)
    except ImportError:
        missing.append(install)

if missing:
    print(f"❌ ขาด dependency: pip install {' '.join(missing)}")
    sys.exit(1)

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import uvicorn
import requests
from PIL import Image
from sentence_transformers import SentenceTransformer
from supabase import create_client

if not SUPABASE_URL or not SUPABASE_KEY:
    print("❌ ยังไม่ได้ตั้งค่า SUPABASE_URL / SUPABASE_KEY")
    sys.exit(1)

# ── Load mCLIP (โหลดครั้งเดียว ค้างใน memory) ─────────────────────
print(f"\n📦 โหลด mCLIP: {EMBED_MODEL}")
print("   (ครั้งแรก download ~400MB — หลังจากนั้น cache ไว้แล้ว)\n")
embedder   = SentenceTransformer(EMBED_MODEL)
VECTOR_DIM = embedder.get_sentence_embedding_dimension()
print(f"✅ mCLIP พร้อม (dim={VECTOR_DIM})\n")

# ── Supabase clients ───────────────────────────────────────────────
# sb_read  = anon key  → search
# sb_write = service key → embed (write mclip_vector, caption, tags)
sb_read  = create_client(SUPABASE_URL, SUPABASE_KEY)
sb_write = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY or SUPABASE_KEY)
print("✅ Supabase พร้อม\n")

# ── FastAPI ────────────────────────────────────────────────────────
app = FastAPI(
    title="VP Library Search + Embed API",
    description="mCLIP multilingual — search และ embed ภาพฉาก VP Library",
    version="3.0.0",
)
_origins = [o.strip() for o in CORS_ORIGINS.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins if "*" not in _origins else ["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# ══════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════

def _encode_image_from_url(image_url: str):
    """ดาวน์โหลดภาพ → mCLIP encode → คืน vector list[float]"""
    try:
        resp = requests.get(image_url, timeout=30)
        resp.raise_for_status()
        img = Image.open(io.BytesIO(resp.content)).convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"ดาวน์โหลดภาพไม่สำเร็จ: {e}")

    try:
        vector = embedder.encode(img, normalize_embeddings=True).tolist()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"mCLIP encode ไม่สำเร็จ: {e}")

    return vector


def _lm_headers() -> dict:
    h = {"Content-Type": "application/json"}
    if LM_STUDIO_KEY:
        h["Authorization"] = f"Bearer {LM_STUDIO_KEY}"
    return h


def _gemma4_tag(image_url: str) -> dict:
    """
    เรียก Gemma4 Vision ผ่าน LM Studio API
    คืน dict: { caption, caption_th, tags, objects, mood, lighting, environment }
    ถ้า LM Studio ไม่เปิด คืน {} เงียบๆ
    """
    if not LM_STUDIO_MODEL:
        return {}

    system_prompt = (
        "You are a visual scene analyst for a virtual production library. "
        "Analyze the image and return ONLY valid JSON, no other text, no markdown."
    )
    user_prompt = """Analyze this virtual production background scene.
Return JSON with exactly these fields:
{
  "caption": "One detailed English sentence describing the scene visually",
  "caption_th": "คำอธิบายภาษาไทยหนึ่งประโยค",
  "tags": ["tag1","tag2"],
  "objects": ["obj1","obj2"],
  "mood": "one_word_mood",
  "lighting": "lighting description",
  "environment": "indoor or outdoor"
}"""

    payload = {
        "model": LM_STUDIO_MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": image_url}},
                    {"type": "text",      "text": user_prompt},
                ],
            },
        ],
        "temperature": 0.2,
        "max_tokens":  512,
    }

    try:
        r = requests.post(
            f"{LM_STUDIO_URL}/chat/completions",
            json=payload,
            headers=_lm_headers(),
            timeout=60,
        )
        r.raise_for_status()
        raw = r.json()["choices"][0]["message"]["content"].strip()
        # strip markdown code block ถ้ามี
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        return json.loads(raw)
    except Exception as e:
        print(f"⚠️  Gemma4 call failed (ข้ามไป): {e}")
        return {}


def _do_embed(scene_id: str, image_url: str, with_tags: bool) -> dict:
    """
    Core logic — encode ภาพ + (optional) tag → update Supabase
    คืน dict สรุปผล
    """
    t0 = time.time()

    # 1. mCLIP image encode
    vector = _encode_image_from_url(image_url)

    # 2. (optional) Gemma4 caption + tags
    tags_data = {}
    if with_tags:
        tags_data = _gemma4_tag(image_url)

    # 3. Build update payload
    now = datetime.now(timezone.utc).isoformat()
    update = {
        "mclip_vector":     vector,
        "mclip_indexed_at": now,
    }
    if tags_data.get("caption"):
        update["mclip_caption"]    = tags_data.get("caption", "")
        update["mclip_caption_th"] = tags_data.get("caption_th", "")
        update["mclip_tags"]       = tags_data.get("tags", [])
        update["mclip_objects"]    = tags_data.get("objects", [])

    # 4. Upsert Supabase
    result = sb_write.from_("scenes").update(update).eq("id", scene_id).execute()
    if hasattr(result, "error") and result.error:
        raise HTTPException(status_code=502, detail=f"Supabase error: {result.error.message}")

    elapsed = round(time.time() - t0, 2)
    return {
        "scene_id":    scene_id,
        "vector_dim":  len(vector),
        "tagged":      bool(tags_data),
        "caption":     tags_data.get("caption", ""),
        "tags":        tags_data.get("tags", []),
        "elapsed_sec": elapsed,
    }


# ══════════════════════════════════════════════════════════════════
# REQUEST / RESPONSE MODELS
# ══════════════════════════════════════════════════════════════════

class SearchRequest(BaseModel):
    query:          str           = Field(..., description="ข้อความค้นหา (ไทยหรืออังกฤษ)")
    limit:          Optional[int] = Field(10, ge=1, le=100)
    min_similarity: Optional[float] = Field(0.05, ge=0.0, le=1.0)


class EmbedRequest(BaseModel):
    scene_id:  str  = Field(..., description="Scene ID เช่น VP-001")
    image_url: str  = Field(..., description="Public URL ของภาพ")
    with_tags: bool = Field(False, description="เรียก Gemma4 ด้วยไหม (ต้องเปิด LM Studio)")


class BulkEmbedRequest(BaseModel):
    scenes:    List[EmbedRequest]
    with_tags: bool = Field(False)


class EncodeRequest(BaseModel):
    text: str


# ══════════════════════════════════════════════════════════════════
# ENDPOINTS
# ══════════════════════════════════════════════════════════════════

@app.get("/")
def root():
    lm_status = "unknown"
    try:
        r = requests.get(f"{LM_STUDIO_URL.replace('/v1','')}/health", timeout=2)
        lm_status = "online" if r.ok else "offline"
    except:
        lm_status = "offline"

    return {
        "service":    "VP Library Search + Embed API",
        "version":    "3.0.0",
        "model":      EMBED_MODEL,
        "vector_dim": VECTOR_DIM,
        "lm_studio":  lm_status,
        "endpoints": {
            "POST /search":      "Semantic search (text → mCLIP → Supabase)",
            "POST /embed":       "Embed ภาพ 1 ฉาก (image → mCLIP → Supabase)",
            "POST /embed/bulk":  "Embed หลายฉากพร้อมกัน",
            "GET  /health":      "Server status",
            "POST /encode":      "Encode text → vector (debug)",
        },
    }


@app.get("/health")
def health():
    return {"status": "ok", "model": EMBED_MODEL, "vector_dim": VECTOR_DIM}


# ── SEARCH ─────────────────────────────────────────────────────────
@app.post("/search")
def search(req: SearchRequest):
    """ค้นหาฉากด้วย text query (Thai/EN) → mCLIP → Supabase pgvector"""
    query = req.query.strip()
    if not query:
        raise HTTPException(status_code=400, detail="query ว่างเปล่า")

    try:
        vector = embedder.encode(query, normalize_embeddings=True).tolist()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"encode ไม่สำเร็จ: {e}")

    try:
        result = sb_read.rpc("match_scenes_mclip", {
            "query_vector":    vector,
            "match_count":     req.limit,
            "match_threshold": req.min_similarity,
        }).execute()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Supabase error: {e}")

    data = result.data or []
    return {"query": query, "model": EMBED_MODEL, "count": len(data), "results": data}


# ── EMBED (single) ─────────────────────────────────────────────────
@app.post("/embed")
def embed_scene(req: EmbedRequest):
    """
    Embed ภาพ 1 ฉากด้วย mCLIP แล้วบันทึกลง Supabase

    - image_url: public URL ของภาพ (จาก Supabase Storage หรือ CDN)
    - with_tags: true → เรียก Gemma4 ด้วย (LM Studio ต้องเปิดอยู่)
    """
    if not req.scene_id or not req.image_url:
        raise HTTPException(status_code=400, detail="scene_id และ image_url จำเป็น")

    result = _do_embed(req.scene_id, req.image_url, req.with_tags)
    return {"status": "ok", **result}


# ── EMBED BULK ─────────────────────────────────────────────────────
@app.post("/embed/bulk")
def embed_bulk(req: BulkEmbedRequest):
    """
    Embed หลายฉากพร้อมกัน (ทำทีละ scene ตามลำดับ)
    คืน results array พร้อมสถานะแต่ละ scene
    """
    results = []
    for scene in req.scenes:
        try:
            r = _do_embed(scene.scene_id, scene.image_url, req.with_tags or scene.with_tags)
            results.append({"status": "ok",    **r})
        except Exception as e:
            results.append({"status": "error", "scene_id": scene.scene_id, "error": str(e)})

    ok_count  = sum(1 for r in results if r["status"] == "ok")
    err_count = len(results) - ok_count
    return {
        "total":   len(results),
        "success": ok_count,
        "failed":  err_count,
        "results": results,
    }


# ── ENCODE (debug) ─────────────────────────────────────────────────
@app.post("/encode")
def encode_text(req: EncodeRequest):
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text ว่างเปล่า")
    vector = embedder.encode(req.text, normalize_embeddings=True).tolist()
    return {"text": req.text, "model": EMBED_MODEL, "dim": len(vector), "vector": vector[:8]}


# ── Start ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"🚀 VP Search+Embed Server: http://{HOST}:{PORT}")
    print(f"   LM Studio: {LM_STUDIO_URL}  (model: {LM_STUDIO_MODEL or 'not set'})\n")
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
