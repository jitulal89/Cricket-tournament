-- V13.4: Use the auction player's assigned category as the
-- authoritative source for the minimum bid.

CREATE OR REPLACE FUNCTION public.auction_minimum_bid(p_player UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT COALESCE(ac.minimum_bid, s.default_minimum_bid, 100)
    FROM public.auction_players ap
    JOIN public.player_registrations pr
      ON pr.id = ap.player_registration_id
    LEFT JOIN public.auction_categories ac
      ON ac.id = ap.category_id
    LEFT JOIN public.auction_settings s
      ON s.tournament_id = ap.tournament_id
    WHERE pr.player_id = p_player
      AND pr.status = 'approved'
    ORDER BY ap.created_at DESC NULLS LAST
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.auction_minimum_bid(UUID) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
