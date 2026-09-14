-- V12: make auction_sessions canonical and make captain refresh reliable

-- Keep the existing current_player_id column for compatibility with existing RPCs,
-- but always synchronize it with current_auction_player_id.
CREATE OR REPLACE FUNCTION public.sync_auction_session_player()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_player_id UUID;
BEGIN
  IF NEW.current_auction_player_id IS NOT NULL THEN
    SELECT pr.player_id
    INTO v_player_id
    FROM public.auction_players ap
    JOIN public.player_registrations pr ON pr.id = ap.player_registration_id
    WHERE ap.id = NEW.current_auction_player_id;
    NEW.current_player_id := v_player_id;
  ELSIF NEW.current_player_id IS NOT NULL THEN
    SELECT ap.id
    INTO NEW.current_auction_player_id
    FROM public.auction_players ap
    JOIN public.player_registrations pr ON pr.id = ap.player_registration_id
    WHERE pr.player_id = NEW.current_player_id
      AND ap.tournament_id = NEW.tournament_id
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_auction_session_player
ON public.auction_sessions;

CREATE TRIGGER trg_sync_auction_session_player
BEFORE INSERT OR UPDATE OF current_auction_player_id, current_player_id, tournament_id
ON public.auction_sessions
FOR EACH ROW
EXECUTE FUNCTION public.sync_auction_session_player();

-- Repair the current Test_Tournament session and any future sessions where the
-- legacy player id is present but the canonical auction-player id is missing.
UPDATE public.auction_sessions s
SET current_auction_player_id = ap.id,
    updated_at = now()
FROM public.auction_players ap
JOIN public.player_registrations pr
  ON pr.id = ap.player_registration_id
WHERE s.tournament_id = '8a7d3343-73e5-43de-b73d-89e355f44bd8'
  AND s.current_player_id = pr.player_id
  AND s.current_auction_player_id IS NULL;

-- Captain access: if the captain already has a profile for this tournament,
-- return that profile immediately. This makes page refresh independent of JWT
-- email parsing. Otherwise use the invite flow to create it.
CREATE OR REPLACE FUNCTION public.claim_captain_access(p_tournament UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  uid UUID := auth.uid();
  em TEXT := lower(COALESCE(auth.jwt()->>'email',''));
  inv public.captain_invites%ROWTYPE;
  existing_profile public.captain_profiles%ROWTYPE;
  pname TEXT;
  result_row public.captain_profiles%ROWTYPE;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Please sign in first';
  END IF;

  SELECT * INTO existing_profile
  FROM public.captain_profiles
  WHERE user_id = uid
    AND tournament_id = p_tournament
  LIMIT 1;

  IF existing_profile.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'user_id', existing_profile.user_id,
      'tournament_id', existing_profile.tournament_id,
      'email', existing_profile.email,
      'display_name', existing_profile.display_name,
      'team_id', existing_profile.team_id
    );
  END IF;

  IF em = '' THEN
    RAISE EXCEPTION 'Please sign in first';
  END IF;

  SELECT * INTO inv
  FROM public.captain_invites
  WHERE tournament_id = p_tournament
    AND active = TRUE
    AND lower(email) = em
  ORDER BY updated_at DESC
  LIMIT 1;

  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'This email is not registered as a captain for this tournament';
  END IF;

  SELECT COALESCE(display_name, full_name)
  INTO pname
  FROM public.players
  WHERE id = inv.player_id;

  INSERT INTO public.captain_profiles(
    user_id,tournament_id,email,display_name,team_id,updated_at
  )
  VALUES(
    uid,p_tournament,em,pname,inv.team_id,now()
  )
  ON CONFLICT(user_id,tournament_id)
  DO UPDATE SET
    email=EXCLUDED.email,
    display_name=EXCLUDED.display_name,
    team_id=EXCLUDED.team_id,
    updated_at=now()
  RETURNING * INTO result_row;

  RETURN jsonb_build_object(
    'user_id', result_row.user_id,
    'tournament_id', result_row.tournament_id,
    'email', result_row.email,
    'display_name', result_row.display_name,
    'team_id', result_row.team_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_captain_access(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_auction_session_player() TO authenticated;

NOTIFY pgrst, 'reload schema';
