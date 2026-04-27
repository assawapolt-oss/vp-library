/**
 * VP Library — Auto-Embed Edge Function
 * ══════════════════════════════════════════════════════════════════
 * ทำงานโดย: Supabase Database Webhook trigger ทุกครั้งที่ INSERT/UPDATE scenes
 * ขั้นตอน: รับ image_url → ดาวน์โหลดภาพ → เรียก HuggingFace CLIP API → อัปเดต mclip_vector
 *
 * Deploy:
 *   supabase functions deploy auto-embed --no-verify-jwt
 *
 * Secrets ที่ต้องตั้งใน Supabase Dashboard → Edge Functions → Secrets:
 *   HF_TOKEN          = hf_xxxxxxxxxxxxxxxxxx   (HuggingFace token ฟรี)
 *   SUPABASE_URL      = https://xxxx.supabase.co (ตั้งอัตโนมัติโดย Supabase)
 *   SUPABASE_SERVICE_ROLE_KEY = eyJ...           (ตั้งอัตโนมัติโดย Supabase)
 *
 * Database Webhook Setup (Supabase Dashboard → Database → Webhooks):
 *   Name:   auto-embed-on-scene-upsert
 *   Table:  scenes
 *   Events: INSERT, UPDATE
 *   URL:    https://<project-ref>.supabase.co/functions/v1/auto-embed
 *   Headers: { "Authorization": "Bearer <SUPABASE_ANON_KEY>" }
 * ══════════════════════════════════════════════════════════════════
 */

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Constants ────────────────────────────────────────────────────
const HF_MODEL_URL =
  'https://router.huggingface.co/hf-inference/models/openai/clip-vit-base-patch32/pipeline/feature-extraction'

// ── L2 Normalize ──────────────────────────────────────────────────
function l2Normalize(vec: number[]): number[] {
  const norm = Math.sqrt(vec.reduce((s, v) => s + v * v, 0))
  return norm > 0 ? vec.map(v => v / norm) : vec
}

// ── Main handler ──────────────────────────────────────────────────
serve(async (req: Request) => {
  // Only accept POST from Supabase webhook
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 })
  }

  // Read env
  const SUPABASE_URL          = Deno.env.get('SUPABASE_URL') ?? ''
  const SUPABASE_SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const HF_TOKEN              = Deno.env.get('HF_TOKEN') ?? ''

  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY || !HF_TOKEN) {
    console.error('[auto-embed] Missing required env vars')
    return new Response(JSON.stringify({ error: 'Server misconfigured' }), { status: 500 })
  }

  // Parse webhook payload from Supabase
  let payload: { type: string; record: Record<string, unknown>; old_record?: Record<string, unknown> }
  try {
    payload = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), { status: 400 })
  }

  const record     = payload.record
  const oldRecord  = payload.old_record
  const sceneId    = record?.id as string | undefined
  const imageUrl   = record?.image_url as string | undefined

  // Skip if no image URL
  if (!sceneId || !imageUrl) {
    return new Response(JSON.stringify({ ok: true, skipped: 'no scene id or image_url' }), { status: 200 })
  }

  // Skip UPDATE where image_url has not changed and already indexed
  if (
    payload.type === 'UPDATE' &&
    record.mclip_indexed_at &&
    oldRecord?.image_url === imageUrl
  ) {
    return new Response(
      JSON.stringify({ ok: true, skipped: `already indexed, image unchanged (${sceneId})` }),
      { status: 200 }
    )
  }

  console.log(`[auto-embed] Processing scene ${sceneId} → ${imageUrl}`)

  try {
    // ── Step 1: Download image ──────────────────────────────────
    const imgResp = await fetch(imageUrl, {
      headers: { 'User-Agent': 'VP-Library-AutoEmbed/1.0' },
    })
    if (!imgResp.ok) {
      throw new Error(`Image fetch failed: ${imgResp.status} ${imgResp.statusText}`)
    }
    const imgBuffer   = await imgResp.arrayBuffer()
    const contentType = imgResp.headers.get('content-type') ?? 'image/webp'
    console.log(`[auto-embed] Downloaded image: ${imgBuffer.byteLength} bytes`)

    // ── Step 2: Call HuggingFace CLIP feature extraction ────────
    // HF Inference API returns the projected 512d CLIP image vector
    // (same space as text vectors from CLIPTextModelWithProjection in browser)
    let hfResp: Response | null = null
    let retries = 0
    while (retries < 3) {
      hfResp = await fetch(HF_MODEL_URL, {
        method:  'POST',
        headers: {
          Authorization:  `Bearer ${HF_TOKEN}`,
          'Content-Type': contentType,
          'x-wait-for-model': 'true',  // wait if model is loading (cold start)
        },
        body: imgBuffer,
      })
      if (hfResp.status === 503) {
        // Model loading — wait and retry
        console.log(`[auto-embed] HF model loading (503), retry ${retries + 1}/3…`)
        await new Promise(r => setTimeout(r, 8000))
        retries++
        continue
      }
      break
    }

    if (!hfResp || !hfResp.ok) {
      const errText = await hfResp?.text() ?? 'no response'
      throw new Error(`HF API error: ${hfResp?.status} — ${errText}`)
    }

    // Response: float[] of length 512 (projected image embedding)
    const rawVector: number[] | number[][] = await hfResp.json()

    // Handle both flat [float...] and nested [[float...]] responses
    const vector: number[] = Array.isArray(rawVector[0])
      ? (rawVector as number[][])[0]
      : (rawVector as number[])

    if (!vector || vector.length < 100) {
      throw new Error(`Unexpected vector shape: length=${vector?.length}`)
    }
    console.log(`[auto-embed] Got vector: dim=${vector.length}`)

    // L2 normalize (same as Colab notebook)
    const normalized = l2Normalize(vector)

    // ── Step 3: Update Supabase ──────────────────────────────────
    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
    const { error: dbError } = await sb
      .from('scenes')
      .update({
        mclip_vector:      normalized,
        mclip_indexed_at:  new Date().toISOString(),
      })
      .eq('id', sceneId)

    if (dbError) throw dbError

    console.log(`[auto-embed] ✅ Scene ${sceneId} embedded successfully (dim=${normalized.length})`)
    return new Response(
      JSON.stringify({ ok: true, id: sceneId, dim: normalized.length }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    )

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error(`[auto-embed] ❌ Error for scene ${sceneId}:`, msg)
    return new Response(
      JSON.stringify({ ok: false, id: sceneId, error: msg }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
})
