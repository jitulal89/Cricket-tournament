-- V14 player auction profile fields
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS profile_photo_url TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS batting_style TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS bowling_style TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_matches INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_runs INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_wickets INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_strike_rate NUMERIC(8,2);
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_economy NUMERIC(8,2);

-- Captains/admins already have player read access in the current setup; refresh API schema.
NOTIFY pgrst, 'reload schema';
