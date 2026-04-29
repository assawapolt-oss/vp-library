-- Add color_palette column to furniture_refs
-- Run this in Supabase SQL Editor to enable color palette extraction on new uploads.
-- (Existing uploads will keep working with or without this column.)

ALTER TABLE furniture_refs
  ADD COLUMN IF NOT EXISTS color_palette text[] DEFAULT '{}';

-- Refresh PostgREST schema cache so the API recognizes the new column immediately
NOTIFY pgrst, 'reload schema';
