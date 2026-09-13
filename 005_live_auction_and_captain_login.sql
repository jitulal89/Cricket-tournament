-- LIVE CATEGORY AUCTION + CAPTAIN LOGIN
-- Run after the existing tournament platform migrations.

ALTER TABLE public.auction_categories
  ADD COLUMN IF NOT EXISTS auction_order INTEGER;

CREATE TABLE IF NOT EXISTS public.auction_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL UNIQUE REFERENCES public.tournaments(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'setup' CHECK (status IN ('setup','ready','live','completed')),
  category_order JSONB NOT NULL DEFAULT '[]'::jsonb,
  category_queues JSONB NOT NULL DEFAULT '{}'::jsonb,
  current_category_index INTEGER NOT NULL DEFAULT 0,
  current_player_id UUID REFERENCES public.players(id) ON DELETE SET NULL,
  current_bid NUMERIC NOT NULL DEFAULT 0,
  leading_team_id UUID REFERENCES public.teams(id) ON DELETE SET NULL,
  current_player_state TEXT NOT NULL DEFAULT 'pending' CHECK (current_player_state IN ('pending','bidding','sold','unsold')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.auction_team_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  team_id UUID NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  starting_purse NUMERIC NOT NULL DEFAULT 0,
  remaining_purse NUMERIC NOT NULL DEFAULT 0,
  UNIQUE(tournament_id, team_id)
);

CREATE TABLE IF NOT EXISTS public.auction_squad (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  team_id UUID NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  player_id UUID NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  purchase_price NUMERIC NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(tournament_id, player_id),
  UNIQUE(tournament_id, team_id, player_id)
);

CREATE TABLE IF NOT EXISTS public.captain_profiles (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  display_name TEXT,
  team_id UUID REFERENCES public.teams(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.auction_bids
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'captain';
ALTER TABLE public.auction_bids
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_auction_categories_order
  ON public.auction_categories(tournament_id, auction_order);
CREATE INDEX IF NOT EXISTS idx_auction_squad_team
  ON public.auction_squad(tournament_id, team_id);
CREATE INDEX IF NOT EXISTS idx_captain_profiles_tournament
  ON public.captain_profiles(tournament_id, team_id);

-- RLS
ALTER TABLE public.auction_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_team_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_squad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.captain_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage auction sessions" ON public.auction_sessions;
CREATE POLICY "Admins manage auction sessions" ON public.auction_sessions
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Public view live auction session" ON public.auction_sessions;
CREATE POLICY "Public view live auction session" ON public.auction_sessions
FOR SELECT TO anon, authenticated USING (
  EXISTS (SELECT 1 FROM public.tournaments t WHERE t.id=tournament_id AND t.status <> 'draft')
);

DROP POLICY IF EXISTS "Admins manage auction wallets" ON public.auction_team_wallets;
CREATE POLICY "Admins manage auction wallets" ON public.auction_team_wallets
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Captains view own wallet" ON public.auction_team_wallets;
CREATE POLICY "Captains view own wallet" ON public.auction_team_wallets
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.captain_profiles cp WHERE cp.user_id=auth.uid() AND cp.team_id=team_id)
);

DROP POLICY IF EXISTS "Admins manage auction squad" ON public.auction_squad;
CREATE POLICY "Admins manage auction squad" ON public.auction_squad
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Public view auction squad" ON public.auction_squad;
CREATE POLICY "Public view auction squad" ON public.auction_squad
FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "Captains view own profile" ON public.captain_profiles;
CREATE POLICY "Captains view own profile" ON public.captain_profiles
FOR SELECT TO authenticated USING (user_id=auth.uid());
DROP POLICY IF EXISTS "Captains create own profile" ON public.captain_profiles;
CREATE POLICY "Captains create own profile" ON public.captain_profiles
FOR INSERT TO authenticated WITH CHECK (user_id=auth.uid());
DROP POLICY IF EXISTS "Captains update own profile" ON public.captain_profiles;
CREATE POLICY "Captains update own profile" ON public.captain_profiles
FOR UPDATE TO authenticated USING (user_id=auth.uid()) WITH CHECK (user_id=auth.uid());
DROP POLICY IF EXISTS "Admins manage captain profiles" ON public.captain_profiles;
CREATE POLICY "Admins manage captain profiles" ON public.captain_profiles
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Make sure auction bid/results tables are usable by admins/captains through RPCs.
GRANT SELECT ON public.auction_sessions, public.auction_team_wallets, public.auction_squad TO anon, authenticated;
GRANT SELECT, INSERT ON public.auction_bids TO authenticated;
GRANT SELECT, INSERT ON public.auction_results TO authenticated;

-- Helper: current auction player minimum bid.
CREATE OR REPLACE FUNCTION public.auction_minimum_bid(p_player UUID)
RETURNS NUMERIC LANGUAGE sql STABLE SET search_path=public AS $$
  SELECT COALESCE(ac.minimum_bid, 0)
  FROM player_registrations pr
  LEFT JOIN auction_categories ac ON ac.id=pr.auction_category_id
  WHERE pr.player_id=p_player AND pr.status='approved'
  ORDER BY pr.registered_at DESC NULLS LAST
  LIMIT 1;
$$;

-- Start auction: categories follow admin-defined auction_order; players are randomly shuffled inside each category.
CREATE OR REPLACE FUNCTION public.start_live_auction(p_tournament UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  s UUID; cat RECORD; r RECORD; q JSONB := '{}'::jsonb; ids JSONB; first_cat UUID; first_player UUID;
  purse NUMERIC;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator access required'; END IF;

  SELECT id INTO s FROM auction_sessions WHERE tournament_id=p_tournament;
  IF s IS NULL THEN
    INSERT INTO auction_sessions(tournament_id,status) VALUES(p_tournament,'ready') RETURNING id INTO s;
  END IF;

  -- Build random queue per category.
  FOR cat IN
    SELECT id FROM auction_categories WHERE tournament_id=p_tournament ORDER BY auction_order NULLS LAST, name
  LOOP
    SELECT jsonb_agg(to_jsonb(x.player_id) ORDER BY random()) INTO ids
    FROM (
      SELECT pr.player_id
      FROM player_registrations pr
      WHERE pr.tournament_id=p_tournament AND pr.status='approved'
        AND pr.is_captain=false AND pr.auction_category_id=cat.id
    ) x;
    q := q || jsonb_build_object(cat.id::text, COALESCE(ids,'[]'::jsonb));
  END LOOP;

  SELECT id INTO first_cat FROM auction_categories WHERE tournament_id=p_tournament ORDER BY auction_order NULLS LAST,name LIMIT 1;
  IF first_cat IS NULL THEN RAISE EXCEPTION 'No auction categories found'; END IF;
  first_player := (q -> (first_cat::text) ->> 0)::uuid;
  IF first_player IS NULL THEN RAISE EXCEPTION 'The first category has no assigned players'; END IF;

  SELECT COALESCE(starting_purse,1000) INTO purse FROM auction_settings WHERE tournament_id=p_tournament;
  INSERT INTO auction_team_wallets(tournament_id,team_id,starting_purse,remaining_purse)
    SELECT p_tournament,t.id,purse,purse FROM teams t WHERE t.tournament_id=p_tournament
    ON CONFLICT(tournament_id,team_id) DO UPDATE SET starting_purse=EXCLUDED.starting_purse,remaining_purse=EXCLUDED.starting_purse;

  UPDATE auction_sessions SET status='live',category_order=(SELECT jsonb_agg(id ORDER BY auction_order NULLS LAST,name) FROM auction_categories WHERE tournament_id=p_tournament),category_queues=q,current_category_index=0,current_player_id=first_player,current_bid=COALESCE(public.auction_minimum_bid(first_player),0),leading_team_id=NULL,current_player_state='bidding',updated_at=now() WHERE id=s;
  UPDATE auction_settings SET auction_status='live' WHERE tournament_id=p_tournament;
  RETURN s;
END;
$$;

-- Place a bid atomically. Captains can only bid for their own team. Admin can bid on behalf of any team.
CREATE OR REPLACE FUNCTION public.place_live_auction_bid(p_tournament UUID,p_team UUID,p_amount NUMERIC,p_source TEXT DEFAULT 'captain')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE s auction_sessions%ROWTYPE; w auction_team_wallets%ROWTYPE; minbid NUMERIC; inc NUMERIC; uid UUID:=auth.uid();
BEGIN
  SELECT * INTO s FROM auction_sessions WHERE tournament_id=p_tournament FOR UPDATE;
  IF s.status<>'live' OR s.current_player_id IS NULL THEN RAISE EXCEPTION 'Auction is not currently accepting bids'; END IF;
  IF p_source='captain' AND NOT EXISTS(SELECT 1 FROM captain_profiles cp WHERE cp.user_id=uid AND cp.team_id=p_team AND cp.tournament_id=p_tournament) THEN RAISE EXCEPTION 'You can only bid for your assigned team'; END IF;
  IF p_source='admin' AND NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator access required'; END IF;
  SELECT * INTO w FROM auction_team_wallets WHERE tournament_id=p_tournament AND team_id=p_team FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'Team purse not initialized'; END IF;
  minbid:=public.auction_minimum_bid(s.current_player_id); SELECT COALESCE(bid_increment,10) INTO inc FROM auction_settings WHERE tournament_id=p_tournament;
  IF p_amount < minbid THEN RAISE EXCEPTION 'Bid must be at least %',minbid; END IF;
  IF s.leading_team_id IS NOT NULL AND p_amount < s.current_bid+inc THEN RAISE EXCEPTION 'Next bid must be at least %',s.current_bid+inc; END IF;
  IF p_amount > w.remaining_purse THEN RAISE EXCEPTION 'Insufficient purse'; END IF;
  INSERT INTO auction_bids(tournament_id,player_id,team_id,bid_amount,source,created_by) VALUES(p_tournament,s.current_player_id,p_team,p_amount,p_source,uid);
  UPDATE auction_sessions SET current_bid=p_amount,leading_team_id=p_team,updated_at=now() WHERE id=s.id;
  RETURN jsonb_build_object('bid',p_amount,'team_id',p_team,'player_id',s.current_player_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_current_auction_player(p_tournament UUID,p_result TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE s auction_sessions%ROWTYPE; cat UUID; arr JSONB; next_player UUID; next_cat UUID; i INT; team_name TEXT; price NUMERIC;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator access required'; END IF;
  SELECT * INTO s FROM auction_sessions WHERE tournament_id=p_tournament FOR UPDATE;
  IF s.status<>'live' OR s.current_player_id IS NULL THEN RAISE EXCEPTION 'No active auction player'; END IF;
  IF p_result NOT IN ('sold','unsold') THEN RAISE EXCEPTION 'Invalid result'; END IF;
  price:=CASE WHEN p_result='sold' THEN s.current_bid ELSE 0 END;

  IF p_result='sold' THEN
    IF s.leading_team_id IS NULL THEN RAISE EXCEPTION 'A sold player must have a winning team'; END IF;
    UPDATE auction_team_wallets SET remaining_purse=remaining_purse-price WHERE tournament_id=p_tournament AND team_id=s.leading_team_id;
    INSERT INTO auction_squad(tournament_id,team_id,player_id,purchase_price) VALUES(p_tournament,s.leading_team_id,s.current_player_id,price);
  END IF;

  INSERT INTO auction_results(tournament_id,player_id,team_id,final_bid,status) VALUES(p_tournament,s.current_player_id,s.leading_team_id,price,p_result);

  cat := (SELECT auction_category_id FROM player_registrations WHERE tournament_id=p_tournament AND player_id=s.current_player_id AND status='approved' LIMIT 1);
  arr := s.category_queues->cat::text;
  FOR i IN 0..GREATEST(jsonb_array_length(arr)-1,0) LOOP
    IF (arr->>i)::uuid=s.current_player_id THEN arr := arr - i; EXIT; END IF;
  END LOOP;
  UPDATE auction_sessions SET category_queues=jsonb_set(category_queues,ARRAY[cat::text],arr),current_player_id=NULL,leading_team_id=NULL,current_bid=0,current_player_state=p_result,updated_at=now() WHERE id=s.id;

  -- Find next player in current category; if empty, move to next category with players.
  SELECT (category_queues->(category_order->>current_category_index)::text->>0)::uuid INTO next_player FROM auction_sessions WHERE id=s.id;
  IF next_player IS NOT NULL THEN
    UPDATE auction_sessions SET current_player_id=next_player,current_bid=public.auction_minimum_bid(next_player),current_player_state='bidding',updated_at=now() WHERE id=s.id;
    RETURN jsonb_build_object('done',false,'player_id',next_player);
  END IF;

  SELECT current_category_index INTO i FROM auction_sessions WHERE id=s.id;
  WHILE i+1 < jsonb_array_length(s.category_order) LOOP
    i:=i+1; next_cat:=(s.category_order->>i)::uuid; next_player:=(s.category_queues->next_cat::text->>0)::uuid;
    IF next_player IS NOT NULL THEN
      UPDATE auction_sessions SET current_category_index=i,current_player_id=next_player,current_bid=public.auction_minimum_bid(next_player),current_player_state='bidding',updated_at=now() WHERE id=s.id;
      RETURN jsonb_build_object('done',false,'player_id',next_player,'category_id',next_cat);
    END IF;
  END LOOP;
  UPDATE auction_sessions SET status='completed',current_player_id=NULL,current_player_state='sold',updated_at=now() WHERE id=s.id;
  UPDATE auction_settings SET auction_status='completed' WHERE tournament_id=p_tournament;
  RETURN jsonb_build_object('done',true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_live_auction(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_live_auction_bid(UUID,UUID,NUMERIC,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finish_current_auction_player(UUID,TEXT) TO authenticated;

-- Captain account can only create a profile for itself. Admin later assigns team_id.

DROP POLICY IF EXISTS "Captains view auction bids" ON public.auction_bids;
CREATE POLICY "Captains view auction bids" ON public.auction_bids
FOR SELECT TO authenticated USING (
  public.is_admin() OR EXISTS (
    SELECT 1 FROM public.captain_profiles cp
    WHERE cp.user_id=auth.uid() AND cp.tournament_id=auction_bids.tournament_id
  )
);
DROP POLICY IF EXISTS "Public view auction results" ON public.auction_results;
CREATE POLICY "Public view auction results" ON public.auction_results
FOR SELECT TO anon, authenticated USING (true);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename='auction_sessions') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.auction_sessions;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename='auction_team_wallets') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.auction_team_wallets;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename='auction_bids') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.auction_bids;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename='captain_profiles') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.captain_profiles;
  END IF;
END $$;

-- Automatically create the captain profile at signup, even when email confirmation is enabled.
CREATE OR REPLACE FUNCTION public.handle_new_captain()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE tid UUID;
BEGIN
  tid := NULLIF(new.raw_user_meta_data->>'tournament_id','')::uuid;
  IF tid IS NOT NULL THEN
    INSERT INTO public.captain_profiles(user_id,tournament_id,email,display_name)
    VALUES(new.id,tid,new.email,new.raw_user_meta_data->>'display_name')
    ON CONFLICT(user_id) DO NOTHING;
  END IF;
  RETURN new;
END;
$$;
DROP TRIGGER IF EXISTS on_auth_user_created_captain ON auth.users;
CREATE TRIGGER on_auth_user_created_captain
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_captain();
