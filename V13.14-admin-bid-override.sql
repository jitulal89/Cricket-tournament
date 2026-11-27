-- V13.14: Admin live auction bid override
-- Admin can replace current bid with any positive amount, choose the new leading team,
-- and bypass normal minimum/increment checks after confirming in the admin UI.
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
