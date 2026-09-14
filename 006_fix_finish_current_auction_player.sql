-- =========================================================
-- 006 FIX: Finish current auction player
-- Matches the actual V6 database schema.
--
-- Existing function signature:
-- finish_current_auction_player(p_tournament uuid, p_result text)
-- =========================================================

DROP FUNCTION IF EXISTS public.finish_current_auction_player(uuid, text);

CREATE OR REPLACE FUNCTION public.finish_current_auction_player(
    p_tournament uuid,
    p_result text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_session public.auction_sessions%ROWTYPE;
    v_current public.auction_players%ROWTYPE;
    v_registration public.player_registrations%ROWTYPE;
    v_player public.players%ROWTYPE;

    v_current_team uuid;
    v_current_bid integer;
    v_event_id uuid;
    v_next_player public.auction_players%ROWTYPE;
    v_next_category uuid;
    v_category_order jsonb;

    v_result text := lower(trim(p_result));
BEGIN
    IF v_result NOT IN ('sold', 'unsold') THEN
        RAISE EXCEPTION 'Result must be sold or unsold';
    END IF;

    -- Lock the auction session so two admin actions cannot
    -- finish the same player at the same time.
    SELECT *
    INTO v_session
    FROM public.auction_sessions
    WHERE tournament_id = p_tournament
    FOR UPDATE;

    IF v_session.id IS NULL THEN
        RAISE EXCEPTION 'Auction session not found';
    END IF;

    IF v_session.status <> 'live' THEN
        RAISE EXCEPTION 'Auction is not live';
    END IF;

    IF v_session.current_auction_player_id IS NULL THEN
        RAISE EXCEPTION 'There is no current auction player';
    END IF;

    SELECT *
    INTO v_current
    FROM public.auction_players
    WHERE id = v_session.current_auction_player_id
      AND tournament_id = p_tournament
    FOR UPDATE;

    IF v_current.id IS NULL THEN
        RAISE EXCEPTION 'Current auction player not found';
    END IF;

    SELECT *
    INTO v_registration
    FROM public.player_registrations
    WHERE id = v_current.player_registration_id;

    IF v_registration.id IS NULL THEN
        RAISE EXCEPTION 'Player registration not found';
    END IF;

    SELECT *
    INTO v_player
    FROM public.players
    WHERE id = v_registration.player_id;

    IF v_player.id IS NULL THEN
        RAISE EXCEPTION 'Player not found';
    END IF;

    v_current_bid := COALESCE(v_session.current_bid, 0);
    v_current_team := v_session.leading_team_id;

    -- =====================================================
    -- SOLD
    -- =====================================================
    IF v_result = 'sold' THEN
        IF v_current_team IS NULL THEN
            RAISE EXCEPTION 'Cannot sell player because there is no leading team';
        END IF;

        IF v_current_bid <= 0 THEN
            RAISE EXCEPTION 'Cannot sell player without a valid bid';
        END IF;

        -- Lock and validate the team's purse.
        PERFORM 1
        FROM public.auction_team_wallets
        WHERE tournament_id = p_tournament
          AND team_id = v_current_team
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Team wallet not found';
        END IF;

        SELECT remaining_purse
        INTO v_current_bid
        FROM public.auction_team_wallets
        WHERE tournament_id = p_tournament
          AND team_id = v_current_team;

        -- Restore the actual winning bid after the purse lookup.
        v_current_bid := COALESCE(v_session.current_bid, 0);

        IF (SELECT remaining_purse
            FROM public.auction_team_wallets
            WHERE tournament_id = p_tournament
              AND team_id = v_current_team) < v_current_bid THEN
            RAISE EXCEPTION
                'Insufficient purse. Required ₹%, available ₹%',
                v_current_bid,
                (SELECT remaining_purse
                 FROM public.auction_team_wallets
                 WHERE tournament_id = p_tournament
                   AND team_id = v_current_team);
        END IF;

        UPDATE public.auction_team_wallets
        SET remaining_purse = remaining_purse - v_current_bid,
            updated_at = now()
        WHERE tournament_id = p_tournament
          AND team_id = v_current_team;

        -- Avoid duplicate squad rows if an admin retries the same action.
        IF NOT EXISTS (
            SELECT 1
            FROM public.auction_squad
            WHERE tournament_id = p_tournament
              AND team_id = v_current_team
              AND player_id = v_registration.player_id
        ) THEN
            INSERT INTO public.auction_squad (
                tournament_id,
                team_id,
                player_id,
                auction_player_id,
                purchase_price
            )
            VALUES (
                p_tournament,
                v_current_team,
                v_registration.player_id,
                v_current.id,
                v_current_bid
            );
        END IF;

        UPDATE public.auction_players
        SET auction_status = 'sold',
            sold_price = v_current_bid,
            sold_team_id = v_current_team
        WHERE id = v_current.id;

    ELSE
        UPDATE public.auction_players
        SET auction_status = 'unsold',
            sold_price = NULL,
            sold_team_id = NULL
        WHERE id = v_current.id;
    END IF;

    -- =====================================================
    -- Finish the current auction event and save result.
    -- =====================================================
    SELECT id
    INTO v_event_id
    FROM public.auction_events
    WHERE tournament_id = p_tournament
      AND auction_player_id = v_current.id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_event_id IS NOT NULL THEN
        UPDATE public.auction_events
        SET status = v_result,
            current_bid = CASE WHEN v_result = 'sold' THEN v_current_bid ELSE NULL END,
            current_team_id = CASE WHEN v_result = 'sold' THEN v_current_team ELSE NULL END,
            ended_at = now()
        WHERE id = v_event_id;

        INSERT INTO public.auction_results (
            auction_event_id,
            auction_player_id,
            result,
            team_id,
            final_price
        )
        VALUES (
            v_event_id,
            v_current.id,
            v_result,
            CASE WHEN v_result = 'sold' THEN v_current_team ELSE NULL END,
            CASE WHEN v_result = 'sold' THEN v_current_bid ELSE NULL END
        )
        ON CONFLICT (auction_event_id)
        DO UPDATE SET
            result = EXCLUDED.result,
            team_id = EXCLUDED.team_id,
            final_price = EXCLUDED.final_price;
    END IF;

    -- =====================================================
    -- Find next pending player in configured category order,
    -- then by randomized auction_order inside the category.
    -- =====================================================
    v_category_order := COALESCE(v_session.category_order, '[]'::jsonb);

    SELECT ap.*
    INTO v_next_player
    FROM public.auction_players ap
    JOIN LATERAL (
        SELECT value::uuid AS category_id,
               ordinality AS category_position
        FROM jsonb_array_elements_text(v_category_order)
        WITH ORDINALITY
    ) co ON co.category_id = ap.category_id
    WHERE ap.tournament_id = p_tournament
      AND ap.auction_status = 'pending'
    ORDER BY co.category_position,
             ap.auction_order NULLS LAST,
             ap.created_at
    LIMIT 1;

    -- =====================================================
    -- Move to next player.
    -- =====================================================
    IF v_next_player.id IS NOT NULL THEN
        v_next_category := v_next_player.category_id;

        INSERT INTO public.auction_events (
            tournament_id,
            auction_player_id,
            status,
            current_bid,
            current_team_id,
            started_at
        )
        VALUES (
            p_tournament,
            v_next_player.id,
            'live',
            0,
            NULL,
            now()
        )
        RETURNING id INTO v_event_id;

        UPDATE public.auction_sessions
        SET status = 'live',
            current_auction_player_id = v_next_player.id,
            current_bid = 0,
            leading_team_id = NULL,
            current_player_state = 'bidding',
            current_player_id = (
                SELECT pr.player_id
                FROM public.player_registrations pr
                WHERE pr.id = v_next_player.player_registration_id
            ),
            updated_at = now()
        WHERE id = v_session.id;

        RETURN jsonb_build_object(
            'success', true,
            'result', v_result,
            'auction_status', 'live',
            'current_auction_player_id', v_next_player.id,
            'current_category_id', v_next_category,
            'current_bid', 0
        );
    END IF;

    -- =====================================================
    -- No more players: complete the auction.
    -- =====================================================
    UPDATE public.auction_sessions
    SET status = 'completed',
        current_auction_player_id = NULL,
        current_player_id = NULL,
        current_bid = 0,
        leading_team_id = NULL,
        current_player_state = 'unsold',
        updated_at = now()
    WHERE id = v_session.id;

    UPDATE public.auction_settings
    SET auction_status = 'completed',
        updated_at = now()
    WHERE tournament_id = p_tournament;

    RETURN jsonb_build_object(
        'success', true,
        'result', v_result,
        'auction_status', 'completed',
        'current_auction_player_id', NULL
    );
END;
$function$;

GRANT EXECUTE
ON FUNCTION public.finish_current_auction_player(uuid, text)
TO authenticated;

NOTIFY pgrst, 'reload schema';
