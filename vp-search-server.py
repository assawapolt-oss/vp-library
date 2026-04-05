#!/usr/bin/env python3
"""
vp-search-server.py — VP Library Semantic Search API
=====================================================
FastAPI server สำหรับ semantic search ด้วย mCLIP multilingual:
  - รับ text query (ไทยหรืออังกฤษก็ได้ ไม่ต้องแปลภาษา)
  - Encode ด้วย mCLIP (clip-ViT-B-32-multilingual-v1)
  - ค้นหาใน Supabase pgvector ด้วย cosine similarity
  - คืนผลลัพธ์พร้อม score

Endpoints:
  GET  /         → หน้า health check
  GET  /health   → สถานะ server
  POST /search   → semantic search หลัก
  POST /encode   → encode text → vector (debug)

วิธีติดตั้ง:
  pip install fastapi uvicorn sentence-transformers supabase python-dotenv

วิธีรัน (local):
  python vp-search-server.py
  เปิด: http://localhost:8766

วิธีรัน (production):
  uvicorn vp-search-server:app --host 0.0.0.0 --port 8766 --workers 2

ไฟล์ config:
  vp-search-server.env (คัดลอกจาก vp-search-server.env.example)
"""

import os
from pathlib import Path
from typing import Optional

# ── โหลด .env ─────────────────────────────────────────────────────
from dotenv import load_dotenv

_env_file = Path(__file__).parent / "vp-search-server.env"
if not _env_file.exists():
    _env_file = Path(__file__).parent / ".env"
load_dotenv(_env_file)

SUPABASE_URL  = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY  = os.environ.get("SUPABASE_KEY", "")    # anon key พอแล้วสำหรับ read
EMBED_MODEL   = os.environ.get("EMBED_MODEL", "clip-ViT-B-32-multilingual-v1")
HOST          = os.environ.get("HOST", "0.0.0.0")
PORT          = int(os.environ.get("PORT", "8766"))
CORS_ORIGINS  = os.environ.get("CORS_ORIGINS", "*")   # หรือใส่ domain จริง เช่น "https://thestandard.co"

# ── ตรวจสอบ dependencies ──────────────────────────────────────────
import sys
missing = []
for pkg, install in [
    ("fastapi",              "fastapi"),
    ("uvicorn",              "uvicorn"),
    ("sentence_transformers","sentence-transformers"),
    ("supabase",             "supabase"),
]:
    try:
        __import__(pkg)
    except ImportError:
        missing.append(install)

if missing:
    print(f"❌ ขาด dependency: pip install {' '.join(missing)}")
    sys.exit(1)

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import uvicorn
from sentence_transformers import SentenceTransformer
from supabase import create_client

# ── ตรวจสอบ config ────────────────────────────────────────────────
if not SUPABASE_URL or not SUPABASE_KEY:
    print("❌ ยังไม่ได้ตั้งค่า SUPABASE_URL / SUPABASE_KEY")
    print("   สร้างไฟล์ vp-search-server.env จาก vp-search-server.env.example")
    sys.exit(1)

# ── โหลด mCLIP (โหลดครั้งเดียวตอนเริ่ม server) ────────────────
print(f"\n📦 โหลด mCLIP model: {EMBED_MODEL}")
print("   (ครั้งแรกจะ download ~400MB — หลังจากนั้น cache ไว้แล้ว)\n")
embedder = SentenceTransformer(EMBED_MODEL)
VECTOR_DIM = embedder.get_sentence_embedding_dimension()
print(f"✅ mCLIP พร้อม (dim={VECTOR_DIM})\n")

# ── เชื่อม Supabase ───────────────────────────────────────────────
print("🔗 เชื่อมต่อ Supabase…")
sb = create_client(SUPABASE_URL, SUPABASE_KEY)
print("✅ Supabase พร้อม\n")

# ── FastAPI App ───────────────────────────────────────────────────
app = FastAPI(
    title="VP Library Semantic Search",
    description="mCLIP multilingual semantic search — รองรับ Thai + English",
    version="2.0.0",
)

# CORS — อนุญาต browser เรียก API จาก domain อื่น
_origins = [o.strip() for o in CORS_ORIGINS.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins if "*" not in _origins else ["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# ── Request/Response Models ───────────────────────────────────────
class SearchRequest(BaseModel):
    query:           str            = Field(..., description="ข้อความค้นหา (ไทยหรืออังกฤษ)")
    limit:           Optional[int]  = Field(10, ge=1, le=50, description="จำนวนผลลัพธ์สูงสุด")
    min_similarity:  Optional[float]= Field(0.05, ge=0.0, le=1.0, description="ค่า cosine similarity ขั้นต่ำ")


class EncodeRequest(BaseModel):
    text: str


# ── Endpoints ─────────────────────────────────────────────────────

@app.get("/")
def root():
    return {
        "service": "VP Library Semantic Search API",
        "version": "2.0.0",
        "model":   EMBED_MODEL,
        "vector_dim": VECTOR_DIM,
        "endpoints": {
            "POST /search":  "Semantic search (text → mCLIP → Supabase pgvector)",
            "GET  /health":  "Server status check",
            "POST /encode":  "Encode text → vector (debug)",
        }
    }


@app.get("/health")
def health():
    return {
        "status":     "ok",
        "model":      EMBED_MODEL,
        "vector_dim": VECTOR_DIM,
    }


@app.post("/search")
def search(req: SearchRequest):
    """
    ค้นหาฉาก VP Library ด้วย natural language (ไทยหรืออังกฤษ)

    - Encode query ด้วย mCLIP multilingual
    - ค้นหาใน Supabase ด้วย HNSW cosine similarity
    - คืนฉากที่ใกล้เคียงที่สุดพร้อม similarity score
    """
    query = req.query.strip()
    if not query:
        raise HTTPException(status_code=400, detail="query ว่างเปล่า")

    # 1. Encode query → vector
    try:
        vector = embedder.encode(query, normalize_embeddings=True).tolist()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"encode ไม่สำเร็จ: {e}")

    # 2. ค้นหาใน Supabase ด้วย match_scenes_mclip RPC
    try:
        result = sb.rpc("match_scenes_mclip", {
            "query_vector":    vector,
            "match_count":     req.limit,
            "match_threshold": req.min_similarity,
        }).execute()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Supabase error: {e}")

    data = result.data or []

    return {
        "query":   query,
        "model":   EMBED_MODEL,
        "count":   len(data),
        "results": data,  # แต่ละ item มี: id, title, title_th, filepath, thumb, world, energy,
                          # context_tags, posture, prod_format, mclip_caption, mclip_tags, similarity
    }


@app.post("/encode")
def encode_text(req: EncodeRequest):
    """Debug endpoint: encode text → vector (ดูค่า vector ที่ได้)"""
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text ว่างเปล่า")

    vector = embedder.encode(req.text, normalize_embeddings=True).tolist()
    return {
        "text":   req.text,
        "model":  EMBED_MODEL,
        "dim":    len(vector),
        "vector": vector[:8],   # แสดงแค่ 8 ค่าแรก (debug)
    }


# ── Start ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"🚀 VP Search Server เริ่มต้นที่ http://{HOST}:{PORT}")
    print(f"   กด Ctrl+C เพื่อหยุด\n")
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
