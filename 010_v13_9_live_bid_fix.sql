-- ============================================
-- V13.9 - FIX LIVE BID FUNCTION
-- Uses auction_sessions.current_auction_player_id
-- as the authoritative current player.
-- ============================================

DROP FUNCTION IF EXISTS public.place_live_auction_bid(UUID, UUID, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS public.place_live_auction_bid(UUID, UUID, INTEGER, TEXT);

CREATE FUNCTION public.place_live_auction_bid(
    p_tournament_id UUID,
    p_team UUID,
    p_amount NUMERIC,
    p_source TEXT DEFAULT 'captain'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    s public.auction_sessions%ROWTYPE;
    w public.auction_team_wallets%ROWTYPE;
    ae public.auction_events%ROWTYPE;
    ap public.auction_players%ROWTYPE;
    v_player_id UUID;
    minbid NUMERIC;
    inc NUMERIC;
    uid UUID := auth.uid();
BEGIN

    SELECT *
    INTO s
    FROM public.auction_sessions
    WHERE tournament_id = p_tournament_id
    FOR UPDATE;

    IF s.id IS NULL OR s.status <> 'live' THEN
        RAISE EXCEPTION 'Auction is not currently accepting bids';
    END IF;

    -- Get the current auction player from the canonical field.
    IF s.current_auction_player_id IS NULL THEN
        RAISE EXCEPTION 'No player is currently up for auction';
    END IF;

    SELECT ap.*
    INTO ap
    FROM public.auction_players ap
    WHERE ap.id = s.current_auction_player_id
      AND ap.tournament_id = p_tournament_id
    LIMIT 1;

    IF ap.id IS NULL THEN
        RAISE EXCEPTION 'Current auction player record not found';
    END IF;

    SELECT pr.player_id
    INTO v_player_id
    FROM public.player_registrations pr
    WHERE pr.id = ap.player_registration_id
    LIMIT 1;

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Current player registration not found';
    END IF;

    IF p_source NOT IN ('captain','admin') THEN
        RAISE EXCEPTION 'Invalid bid source';
    END IF;

    IF p_source = 'captain' AND NOT EXISTS (
        SELECT 1
        FROM public.captain_profiles cp
        WHERE cp.user_id = uid
          AND cp.team_id = p_team
          AND cp.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION 'You can only bid for your assigned team';
    END IF;

    IF p_source = 'admin' AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Administrator access required';
    END IF;

    SELECT *
    INTO ae
    FROM public.auction_events
    WHERE tournament_id = p_tournament_id
      AND auction_player_id = ap.id
      AND status = 'live'
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF ae.id IS NULL THEN
        RAISE EXCEPTION 'Current auction event not found';
    END IF;

    SELECT *
    INTO w
    FROM public.auction_team_wallets
    WHERE tournament_id = p_tournament_id
      AND team_id = p_team
    FOR UPDATE;

    IF w.id IS NULL THEN
        RAISE EXCEPTION 'Team purse not initialized';
    END IF;

    -- Category minimum is authoritative.
    SELECT COALESCE(ac.minimum_bid, s2.default_minimum_bid, 100)
    INTO minbid
    FROM public.auction_categories ac
    RIGHT JOIN public.auction_settings s2
      ON s2.tournament_id = p_tournament_id
    WHERE ac.id = ap.category_id
    LIMIT 1;

    minbid := COALESCE(minbid, 100);

    SELECT COALESCE(bid_increment, 10)
    INTO inc
    FROM public.auction_settings
    WHERE tournament_id = p_tournament_id;

    inc := COALESCE(inc, 10);

    IF p_amount < minbid THEN
        RAISE EXCEPTION 'Bid must be at least %', minbid;
    END IF;

    IF s.leading_team_id IS NOT NULL
       AND p_amount < s.current_bid + inc THEN
        RAISE EXCEPTION 'Next bid must be at least %', s.current_bid + inc;
    END IF;

    IF p_amount > w.remaining_purse THEN
        RAISE EXCEPTION 'Insufficient purse';
    END IF;

    INSERT INTO public.auction_bids (
        auction_event_id,
        team_id,
        bid_amount,
        source,
        created_by
    )
    VALUES (
        ae.id,
        p_team,
        p_amount,
        p_source,
        uid
    );

    UPDATE public.auction_events
    SET
        current_bid = p_amount,
        current_team_id = p_team
    WHERE id = ae.id;

    UPDATE public.auction_sessions
    SET
        current_bid = p_amount,
        leading_team_id = p_team,
        updated_at = now()
    WHERE id = s.id;

    RETURN jsonb_build_object(
        'bid', p_amount,
        'team_id', p_team,
        'player_id', v_player_id,
        'auction_player_id', ap.id,
        'auction_event_id', ae.id
    );

END;
$$;

GRANT EXECUTE
ON FUNCTION public.place_live_auction_bid(UUID, UUID, NUMERIC, TEXT)
TO authenticated;

NOTIFY pgrst, 'reload schema';
