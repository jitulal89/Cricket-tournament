-- V13.18: Configure and enforce squad size per team.
-- Squad size includes the captain. Default 11 means captain + up to 10 auction purchases.
ALTER TABLE public.auction_settings
  ADD COLUMN IF NOT EXISTS players_per_team INTEGER NOT NULL DEFAULT 11;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='auction_settings_players_per_team_check'
      AND conrelid='public.auction_settings'::regclass
  ) THEN
    ALTER TABLE public.auction_settings
      ADD CONSTRAINT auction_settings_players_per_team_check
      CHECK (players_per_team BETWEEN 2 AND 30);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.place_live_auction_bid(
  p_tournament_id UUID,
  p_team UUID,
  p_amount NUMERIC,
  p_source TEXT DEFAULT 'captain'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  s public.auction_sessions%ROWTYPE;
  w public.auction_team_wallets%ROWTYPE;
  ae public.auction_events%ROWTYPE;
  ap_id UUID;
  minbid NUMERIC;
  inc NUMERIC;
  squad_limit INTEGER := 11;
  roster_count INTEGER := 0;
  captain_count INTEGER := 0;
  uid UUID := auth.uid();
BEGIN
  SELECT * INTO s
  FROM public.auction_sessions
  WHERE tournament_id=p_tournament_id
  FOR UPDATE;

  IF s.id IS NULL OR s.status<>'live' OR s.current_player_id IS NULL THEN
    RAISE EXCEPTION 'Auction is not currently accepting bids';
  END IF;

  IF p_source NOT IN ('captain','admin') THEN RAISE EXCEPTION 'Invalid bid source'; END IF;

  IF p_source='captain' AND NOT EXISTS(
    SELECT 1 FROM public.captain_profiles cp
    WHERE cp.user_id=uid AND cp.team_id=p_team AND cp.tournament_id=p_tournament_id
  ) THEN
    RAISE EXCEPTION 'You can only bid for your assigned team';
  END IF;

  IF p_source='admin' AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Administrator access required';
  END IF;

  SELECT ap.id INTO ap_id
  FROM public.auction_players ap
  JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
  WHERE ap.tournament_id=p_tournament_id AND pr.player_id=s.current_player_id
  LIMIT 1;

  IF ap_id IS NULL THEN RAISE EXCEPTION 'Current auction player record not found'; END IF;

  SELECT * INTO ae
  FROM public.auction_events
  WHERE tournament_id=p_tournament_id
    AND auction_player_id=ap_id
    AND status='live'
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF ae.id IS NULL THEN RAISE EXCEPTION 'Current auction event not found'; END IF;

  SELECT * INTO w
  FROM public.auction_team_wallets
  WHERE tournament_id=p_tournament_id AND team_id=p_team
  FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'Team purse not initialized'; END IF;

  SELECT COALESCE(players_per_team,11) INTO squad_limit
  FROM public.auction_settings
  WHERE tournament_id=p_tournament_id;
  squad_limit := COALESCE(squad_limit,11);

  SELECT COUNT(*) INTO roster_count
  FROM public.auction_players
  WHERE tournament_id=p_tournament_id
    AND sold_team_id=p_team
    AND auction_status='sold';

  SELECT CASE WHEN captain_id IS NULL THEN 0 ELSE 1 END INTO captain_count
  FROM public.teams
  WHERE tournament_id=p_tournament_id AND id=p_team;

  IF roster_count + COALESCE(captain_count,0) >= squad_limit THEN
    RAISE EXCEPTION 'Team squad is full (% players). Increase the squad size in Pre-Auction Setup or choose another team.', squad_limit;
  END IF;

  minbid:=public.auction_minimum_bid(s.current_player_id);
  SELECT COALESCE(bid_increment,10) INTO inc
  FROM public.auction_settings WHERE tournament_id=p_tournament_id;
  inc:=COALESCE(inc,10);

  IF p_amount < minbid THEN RAISE EXCEPTION 'Bid must be at least %',minbid; END IF;
  IF s.leading_team_id IS NOT NULL AND p_amount < s.current_bid+inc THEN
    RAISE EXCEPTION 'Next bid must be at least %',s.current_bid+inc;
  END IF;
  IF p_amount > w.remaining_purse THEN RAISE EXCEPTION 'Insufficient purse'; END IF;

  INSERT INTO public.auction_bids(auction_event_id,team_id,bid_amount,source,created_by)
  VALUES(ae.id,p_team,p_amount,p_source,uid);

  UPDATE public.auction_events
  SET current_bid=p_amount,current_team_id=p_team
  WHERE id=ae.id;

  UPDATE public.auction_sessions
  SET current_bid=p_amount,leading_team_id=p_team,updated_at=now()
  WHERE id=s.id;

  RETURN jsonb_build_object('bid',p_amount,'team_id',p_team,'player_id',s.current_player_id,'auction_event_id',ae.id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_live_auction_bid(UUID,UUID,NUMERIC,TEXT)
TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_override_live_auction_bid(
  p_tournament_id UUID,
  p_team_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  s public.auction_sessions%ROWTYPE;
  w public.auction_team_wallets%ROWTYPE;
  ae public.auction_events%ROWTYPE;
  ap_id UUID;
  squad_limit INTEGER := 11;
  roster_count INTEGER := 0;
  captain_count INTEGER := 0;
  uid UUID := auth.uid();
BEGIN
  IF uid IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Administrator access required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Override bid must be greater than zero';
  END IF;

  SELECT * INTO s
  FROM public.auction_sessions
  WHERE tournament_id=p_tournament_id
  FOR UPDATE;

  IF s.id IS NULL OR s.status<>'live' OR s.current_player_id IS NULL THEN
    RAISE EXCEPTION 'Auction is not currently accepting bids';
  END IF;

  SELECT ap.id INTO ap_id
  FROM public.auction_players ap
  JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
  WHERE ap.tournament_id=p_tournament_id
    AND pr.player_id=s.current_player_id
  LIMIT 1;

  IF ap_id IS NULL THEN
    RAISE EXCEPTION 'Current auction player record not found';
  END IF;

  SELECT * INTO ae
  FROM public.auction_events
  WHERE tournament_id=p_tournament_id
    AND auction_player_id=ap_id
    AND status='live'
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF ae.id IS NULL THEN
    RAISE EXCEPTION 'Current auction event not found';
  END IF;

  SELECT * INTO w
  FROM public.auction_team_wallets
  WHERE tournament_id=p_tournament_id
    AND team_id=p_team_id
  FOR UPDATE;

  IF w.id IS NULL THEN
    RAISE EXCEPTION 'Selected team purse is not initialized';
  END IF;

  SELECT COALESCE(players_per_team,11) INTO squad_limit
  FROM public.auction_settings
  WHERE tournament_id=p_tournament_id;
  squad_limit := COALESCE(squad_limit,11);

  SELECT COUNT(*) INTO roster_count
  FROM public.auction_players
  WHERE tournament_id=p_tournament_id
    AND sold_team_id=p_team_id
    AND auction_status='sold';

  SELECT CASE WHEN captain_id IS NULL THEN 0 ELSE 1 END INTO captain_count
  FROM public.teams
  WHERE tournament_id=p_tournament_id AND id=p_team_id;

  IF roster_count + COALESCE(captain_count,0) >= squad_limit THEN
    RAISE EXCEPTION 'Selected team squad is full (% players).', squad_limit;
  END IF;

  IF p_amount > w.remaining_purse THEN
    RAISE EXCEPTION 'Override amount exceeds selected team remaining purse';
  END IF;

  INSERT INTO public.auction_bids(auction_event_id,team_id,bid_amount,source,created_by)
  VALUES(ae.id,p_team_id,p_amount,'admin_override',uid);

  UPDATE public.auction_events
  SET current_bid=p_amount,current_team_id=p_team_id
  WHERE id=ae.id;

  UPDATE public.auction_sessions
  SET current_bid=p_amount,leading_team_id=p_team_id,updated_at=now()
  WHERE id=s.id;

  RETURN jsonb_build_object(
    'override',true,
    'bid',p_amount,
    'team_id',p_team_id,
    'previous_bid',s.current_bid,
    'previous_team_id',s.leading_team_id,
    'player_id',s.current_player_id,
    'auction_event_id',ae.id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_override_live_auction_bid(UUID,UUID,NUMERIC)
TO authenticated;

NOTIFY pgrst, 'reload schema';
