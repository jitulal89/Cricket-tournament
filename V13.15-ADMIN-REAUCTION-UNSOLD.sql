-- V13.15: Admin re-auction of an unsold player
-- Apply in Supabase SQL Editor after V13.14.

CREATE OR REPLACE FUNCTION public.admin_reauction_unsold_player(
    p_tournament_id UUID,
    p_auction_player_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_session public.auction_sessions%ROWTYPE;
    v_ap public.auction_players%ROWTYPE;
    v_player_id UUID;
    v_minimum_bid NUMERIC := 0;
    v_category_index INTEGER := 0;
    v_event_id UUID;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Administrator access required';
    END IF;

    SELECT * INTO v_session
    FROM public.auction_sessions
    WHERE tournament_id = p_tournament_id
    FOR UPDATE;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION 'Auction session not found. Start the auction first.';
    END IF;

    IF v_session.current_auction_player_id IS NOT NULL THEN
        RAISE EXCEPTION 'Finish the current player before starting a re-auction';
    END IF;

    SELECT * INTO v_ap
    FROM public.auction_players
    WHERE id = p_auction_player_id
      AND tournament_id = p_tournament_id
    FOR UPDATE;

    IF v_ap.id IS NULL THEN
        RAISE EXCEPTION 'Auction player not found for this tournament';
    END IF;

    IF v_ap.auction_status <> 'unsold' THEN
        RAISE EXCEPTION 'Only an unsold player can be re-auctioned';
    END IF;

    SELECT pr.player_id
    INTO v_player_id
    FROM public.player_registrations pr
    WHERE pr.id = v_ap.player_registration_id
      AND pr.tournament_id = p_tournament_id;

    IF v_player_id IS NULL THEN
        RAISE EXCEPTION 'Player registration or player record not found';
    END IF;

    SELECT COALESCE(minimum_bid, 0)
    INTO v_minimum_bid
    FROM public.auction_categories
    WHERE id = v_ap.category_id
      AND tournament_id = p_tournament_id;
    v_minimum_bid := COALESCE(v_minimum_bid, 0);

    IF jsonb_typeof(COALESCE(v_session.category_order, '[]'::jsonb)) = 'array' THEN
        SELECT COALESCE(ordinality - 1, 0)
        INTO v_category_index
        FROM jsonb_array_elements_text(COALESCE(v_session.category_order, '[]'::jsonb))
             WITH ORDINALITY AS c(category_id, ordinality)
        WHERE c.category_id = v_ap.category_id::text
        LIMIT 1;
        v_category_index := COALESCE(v_category_index, 0);
    END IF;

    UPDATE public.auction_players
    SET auction_status = 'live',
        sold_price = NULL,
        sold_team_id = NULL
    WHERE id = v_ap.id;

    INSERT INTO public.auction_events (
        tournament_id,
        auction_player_id,
        status,
        current_bid,
        current_team_id,
        started_at
    )
    VALUES (
        p_tournament_id,
        v_ap.id,
        'live',
        0,
        NULL,
        now()
    )
    RETURNING id INTO v_event_id;

    UPDATE public.auction_sessions
    SET status = 'live',
        current_auction_player_id = v_ap.id,
        current_player_id = v_player_id,
        current_category_index = v_category_index,
        current_bid = 0,
        leading_team_id = NULL,
        current_player_state = 'bidding',
        updated_at = now()
    WHERE id = v_session.id;

    UPDATE public.auction_settings
    SET auction_status = 'live',
        updated_at = now()
    WHERE tournament_id = p_tournament_id;

    RETURN jsonb_build_object(
        'success', true,
        'auction_player_id', v_ap.id,
        'player_id', v_player_id,
        'event_id', v_event_id,
        'minimum_bid', v_minimum_bid,
        'auction_status', 'live'
    );
END;
$function$;

GRANT EXECUTE
ON FUNCTION public.admin_reauction_unsold_player(uuid, uuid)
TO authenticated;

NOTIFY pgrst, 'reload schema';
