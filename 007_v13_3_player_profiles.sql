
-- V13.3: Player photo + player profile/stat fields
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS profile_photo_url TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS batting_style TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS bowling_style TEXT;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_matches INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_runs INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_wickets INTEGER;
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_strike_rate NUMERIC(8,2);
ALTER TABLE public.players ADD COLUMN IF NOT EXISTS cricheroes_economy NUMERIC(8,2);

INSERT INTO storage.buckets (id,name,public)
VALUES ('player-photos','player-photos',true)
ON CONFLICT (id) DO UPDATE SET public=true;

DROP POLICY IF EXISTS "Public can view player photos" ON storage.objects;
CREATE POLICY "Public can view player photos"
ON storage.objects FOR SELECT TO public
USING (bucket_id='player-photos');

DROP POLICY IF EXISTS "Anyone can upload player registration photos" ON storage.objects;
CREATE POLICY "Anyone can upload player registration photos"
ON storage.objects FOR INSERT TO anon, authenticated
WITH CHECK (bucket_id='player-photos');

DROP POLICY IF EXISTS "Admins can update player photos" ON storage.objects;
CREATE POLICY "Admins can update player photos"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id='player-photos' AND public.is_admin())
WITH CHECK (bucket_id='player-photos' AND public.is_admin());

DROP POLICY IF EXISTS "Admins can delete player photos" ON storage.objects;
CREATE POLICY "Admins can delete player photos"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id='player-photos' AND public.is_admin());

NOTIFY pgrst, 'reload schema';
