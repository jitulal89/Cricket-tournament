-- V13.25: Fix public player registration RLS
-- Public registration creates a player record, then a pending registration.
-- The browser only needs INSERT permission; it does not need to read the
-- inserted player row or the registration row back.

ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_registrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public player registration insert" ON public.players;
CREATE POLICY "Public player registration insert"
ON public.players
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

GRANT INSERT ON TABLE public.players TO anon, authenticated;

DROP POLICY IF EXISTS "Public pending player registration insert" ON public.player_registrations;
CREATE POLICY "Public pending player registration insert"
ON public.player_registrations
FOR INSERT
TO anon, authenticated
WITH CHECK (status = 'pending');

GRANT INSERT ON TABLE public.player_registrations TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
