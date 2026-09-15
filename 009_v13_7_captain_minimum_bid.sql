-- V13.7: Captain page authoritative current-auction info
-- Reads the current session inside SECURITY DEFINER so Captain RLS
-- cannot cause the category/minimum to appear as zero.

DROP FUNCTION IF EXISTS public.get_current_captain_auction_info(UUID);

CREATE FUNCTION public.get_current_captain_auction_info(
    p_tournament_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_player_id UUID;
    v_category_id UUID;
    v_category_name TEXT;
    v_minimum_bid INTEGER;
BEGIN
    SELECT
        ap.id,
        ap.category_id
    INTO
        v_player_id,
        v_category_id
    FROM public.auction_sessions s
    JOIN public.auction_players ap
      ON ap.id = s.current_auction_player_id
    WHERE s.tournament_id = p_tournament_id
    LIMIT 1;

    IF v_player_id IS NULL THEN
        RETURN jsonb_build_object(
            'minimum_bid', 0,
            'category_name', NULL
        );
    END IF;

    SELECT
        ac.name,
        ac.minimum_bid
    INTO
        v_category_name,
        v_minimum_bid
    FROM public.auction_categories ac
    WHERE ac.id = v_category_id
    LIMIT 1;

    RETURN jsonb_build_object(
        'minimum_bid', COALESCE(v_minimum_bid, 0),
        'category_name', v_category_name
    );
END;
$$;

GRANT EXECUTE
ON FUNCTION public.get_current_captain_auction_info(UUID)
TO authenticated;

NOTIFY pgrst, 'reload schema';
