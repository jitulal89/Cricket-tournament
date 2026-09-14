-- LIVE CATEGORY AUCTION + CAPTAIN LOGIN (V5)
-- Corrected to use the existing auction_events / auction_bids / auction_results schema.
-- Captain login is prepared by admin with an email during captain selection.
-- Captain then signs in with a Supabase one-time email link (no service-role key in browser).

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

-- Admin creates the captain login record here during Pre-Auction Setup.
CREATE TABLE IF NOT EXISTS public.captain_invites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  team_id UUID NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  player_id UUID NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(tournament_id, team_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_captain_invites_active_email
  ON public.captain_invites(tournament_id, lower(email))
  WHERE active = TRUE;

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
CREATE INDEX IF NOT EXISTS idx_captain_invites_tournament_team
  ON public.captain_invites(tournament_id, team_id);
CREATE INDEX IF NOT EXISTS idx_auction_events_tournament_status
  ON public.auction_events(tournament_id, status);
CREATE INDEX IF NOT EXISTS idx_auction_bids_event_created
  ON public.auction_bids(auction_event_id, created_at);

-- RLS
ALTER TABLE public.auction_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_team_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_squad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.captain_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.captain_invites ENABLE ROW LEVEL SECURITY;

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
DROP POLICY IF EXISTS "Captains update own profile" ON public.captain_profiles;
DROP POLICY IF EXISTS "Admins manage captain profiles" ON public.captain_profiles;
CREATE POLICY "Admins manage captain profiles" ON public.captain_profiles
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "Admins manage captain invites" ON public.captain_invites;
CREATE POLICY "Admins manage captain invites" ON public.captain_invites
FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Captains view own invite" ON public.captain_invites;
CREATE POLICY "Captains view own invite" ON public.captain_invites
FOR SELECT TO authenticated USING (
  active = TRUE AND lower(email) = lower(COALESCE(auth.jwt()->>'email',''))
);

-- Existing auction_bids has auction_event_id and team_id; it does NOT have tournament_id/player_id.
DROP POLICY IF EXISTS "Captains view auction bids" ON public.auction_bids;
DROP POLICY IF EXISTS "Public view auction bids" ON public.auction_bids;
CREATE POLICY "Captains view auction bids" ON public.auction_bids
FOR SELECT TO authenticated USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1
    FROM public.auction_events ae
    JOIN public.captain_profiles cp
      ON cp.tournament_id = ae.tournament_id
    WHERE ae.id = auction_bids.auction_event_id
      AND cp.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Public view auction results" ON public.auction_results;
CREATE POLICY "Public view auction results" ON public.auction_results
FOR SELECT TO anon, authenticated USING (true);

GRANT SELECT ON public.auction_sessions, public.auction_team_wallets, public.auction_squad, public.captain_invites TO anon, authenticated;
GRANT SELECT, INSERT ON public.auction_bids TO authenticated;
GRANT SELECT, INSERT ON public.auction_results TO authenticated;

-- Minimum bid for the player's approved registration.
CREATE OR REPLACE FUNCTION public.auction_minimum_bid(p_player UUID)
RETURNS NUMERIC LANGUAGE sql STABLE SET search_path=public AS $$
  SELECT COALESCE(ac.minimum_bid, 0)
  FROM public.player_registrations pr
  LEFT JOIN public.auction_categories ac ON ac.id=pr.auction_category_id
  WHERE pr.player_id=p_player AND pr.status='approved'
  ORDER BY pr.registered_at DESC NULLS LAST
  LIMIT 1;
$$;

-- Start auction. Categories use auction_order; players are randomly shuffled inside each category.
-- Existing auction_players rows are created/updated from approved registrations before the queue is built.
CREATE OR REPLACE FUNCTION public.start_live_auction(p_tournament_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  s UUID;
  cat RECORD;
  r RECORD;
  q JSONB := '{}'::jsonb;
  ids JSONB;
  category_order_json JSONB := '[]'::jsonb;
  first_cat UUID;
  first_player UUID;
  first_index INTEGER := -1;
  i INTEGER;
  purse NUMERIC;
  event_id UUID;
  ap_id UUID;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator access required'; END IF;

  SELECT id, status INTO s, r FROM public.auction_sessions WHERE tournament_id=p_tournament_id;
  IF r.status IN ('live','completed') THEN
    RAISE EXCEPTION 'Auction is already %', r.status;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.teams WHERE tournament_id=p_tournament_id) THEN
    RAISE EXCEPTION 'No teams found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.player_registrations pr
    WHERE pr.tournament_id=p_tournament_id AND pr.status='approved'
      AND pr.is_captain=FALSE AND pr.auction_category_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Every non-captain player must be assigned to a category';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.auction_categories WHERE tournament_id=p_tournament_id) THEN
    RAISE EXCEPTION 'No auction categories found';
  END IF;

  -- Keep auction_players in sync with the approved, non-captain registration list.
  INSERT INTO public.auction_players(tournament_id, player_registration_id, category_id, auction_status)
  SELECT pr.tournament_id, pr.id, pr.auction_category_id, 'pending'
  FROM public.player_registrations pr
  WHERE pr.tournament_id=p_tournament_id
    AND pr.status='approved'
    AND pr.is_captain=FALSE
  ON CONFLICT (tournament_id, player_registration_id)
  DO UPDATE SET category_id=EXCLUDED.category_id;

  IF s IS NULL THEN
    INSERT INTO public.auction_sessions(tournament_id,status)
    VALUES(p_tournament_id,'ready') RETURNING id INTO s;
  END IF;

  -- Build category order and a randomized player queue for every category.
  FOR cat IN
    SELECT id, auction_order, name
    FROM public.auction_categories
    WHERE tournament_id=p_tournament_id
    ORDER BY auction_order NULLS LAST, name
  LOOP
    category_order_json := category_order_json || jsonb_build_array(cat.id::text);

    SELECT jsonb_agg(to_jsonb(x.player_id) ORDER BY random()) INTO ids
    FROM (
      SELECT pr.player_id
      FROM public.player_registrations pr
      WHERE pr.tournament_id=p_tournament_id
        AND pr.status='approved'
        AND pr.is_captain=FALSE
        AND pr.auction_category_id=cat.id
    ) x;

    q := q || jsonb_build_object(cat.id::text, COALESCE(ids,'[]'::jsonb));
  END LOOP;

  -- Pick the first category that actually contains players; empty categories are skipped.
  FOR i IN 0..GREATEST(jsonb_array_length(category_order_json)-1,0) LOOP
    first_cat := (category_order_json->>i)::uuid;
    first_player := (q->(first_cat::text)->>0)::uuid;
    IF first_player IS NOT NULL THEN
      first_index := i;
      EXIT;
    END IF;
  END LOOP;

  IF first_player IS NULL THEN RAISE EXCEPTION 'No auction players found'; END IF;

  SELECT COALESCE(starting_purse,1000) INTO purse
  FROM public.auction_settings WHERE tournament_id=p_tournament_id;
  purse := COALESCE(purse,1000);

  INSERT INTO public.auction_team_wallets(tournament_id,team_id,starting_purse,remaining_purse)
  SELECT p_tournament_id,t.id,purse,purse
  FROM public.teams t
  WHERE t.tournament_id=p_tournament_id
  ON CONFLICT(tournament_id,team_id)
  DO UPDATE SET starting_purse=EXCLUDED.starting_purse,
                remaining_purse=EXCLUDED.starting_purse;

  SELECT ap.id INTO ap_id
  FROM public.auction_players ap
  JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
  WHERE ap.tournament_id=p_tournament_id AND pr.player_id=first_player;

  IF ap_id IS NULL THEN RAISE EXCEPTION 'Auction player record not found'; END IF;

  INSERT INTO public.auction_events(tournament_id,auction_player_id,status,current_bid,current_team_id,started_at)
  VALUES(p_tournament_id,ap_id,'live',public.auction_minimum_bid(first_player),NULL,now())
  RETURNING id INTO event_id;

  UPDATE public.auction_players
  SET auction_status='live', auction_order=1
  WHERE id=ap_id;

  UPDATE public.auction_sessions
  SET status='live',
      category_order=category_order_json,
      category_queues=q,
      current_category_index=first_index,
      current_player_id=first_player,
      current_bid=public.auction_minimum_bid(first_player),
      leading_team_id=NULL,
      current_player_state='bidding',
      updated_at=now()
  WHERE id=s;

  UPDATE public.auction_settings SET auction_status='live' WHERE tournament_id=p_tournament_id;
  RETURN s;
END;
$$;

-- Place a bid atomically. Captain bids are restricted to that captain's assigned team.
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

-- Finish the current player, record the result, update purse/squad, then open the next player.
CREATE OR REPLACE FUNCTION public.finish_current_auction_player(p_tournament_id UUID,p_result TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  s public.auction_sessions%ROWTYPE;
  ae public.auction_events%ROWTYPE;
  aprow public.auction_players%ROWTYPE;
  next_ap_id UUID;
  cat UUID;
  arr JSONB;
  next_player UUID;
  next_cat UUID;
  i INT;
  price NUMERIC;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Administrator access required'; END IF;
  IF p_result NOT IN ('sold','unsold') THEN RAISE EXCEPTION 'Invalid result'; END IF;

  SELECT * INTO s FROM public.auction_sessions WHERE tournament_id=p_tournament_id FOR UPDATE;
  IF s.id IS NULL OR s.status<>'live' OR s.current_player_id IS NULL THEN
    RAISE EXCEPTION 'No active auction player';
  END IF;

  SELECT ap.* INTO aprow
  FROM public.auction_players ap
  JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
  WHERE ap.tournament_id=p_tournament_id AND pr.player_id=s.current_player_id
  LIMIT 1;

  IF aprow.id IS NULL THEN RAISE EXCEPTION 'Current auction player record not found'; END IF;

  SELECT * INTO ae
  FROM public.auction_events
  WHERE tournament_id=p_tournament_id AND auction_player_id=aprow.id AND status='live'
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF ae.id IS NULL THEN RAISE EXCEPTION 'Current auction event not found'; END IF;

  price:=CASE WHEN p_result='sold' THEN s.current_bid ELSE 0 END;

  IF p_result='sold' THEN
    IF s.leading_team_id IS NULL THEN RAISE EXCEPTION 'A sold player must have a winning team'; END IF;
    UPDATE public.auction_team_wallets
    SET remaining_purse=remaining_purse-price
    WHERE tournament_id=p_tournament_id AND team_id=s.leading_team_id;

    INSERT INTO public.auction_squad(tournament_id,team_id,player_id,purchase_price)
    VALUES(p_tournament_id,s.leading_team_id,s.current_player_id,price)
    ON CONFLICT (tournament_id,player_id) DO UPDATE
      SET team_id=EXCLUDED.team_id,purchase_price=EXCLUDED.purchase_price;
  END IF;

  UPDATE public.auction_events
  SET status='completed',ended_at=now(),current_bid=s.current_bid,current_team_id=s.leading_team_id
  WHERE id=ae.id;

  INSERT INTO public.auction_results(auction_event_id,auction_player_id,result,team_id,final_price)
  VALUES(ae.id,aprow.id,p_result,CASE WHEN p_result='sold' THEN s.leading_team_id ELSE NULL END,price)
  ON CONFLICT (auction_event_id) DO UPDATE SET
    result=EXCLUDED.result,
    team_id=EXCLUDED.team_id,
    final_price=EXCLUDED.final_price;

  UPDATE public.auction_players
  SET auction_status=p_result,sold_price=CASE WHEN p_result='sold' THEN price ELSE NULL END,
      sold_team_id=CASE WHEN p_result='sold' THEN s.leading_team_id ELSE NULL END
  WHERE id=aprow.id;

  cat := aprow.category_id;
  arr := COALESCE(s.category_queues->(cat::text),'[]'::jsonb);
  FOR i IN 0..GREATEST(jsonb_array_length(arr)-1,0) LOOP
    IF (arr->>i)::uuid=s.current_player_id THEN arr := arr - i; EXIT; END IF;
  END LOOP;

  UPDATE public.auction_sessions
  SET category_queues=jsonb_set(s.category_queues,ARRAY[cat::text],arr),
      current_player_id=NULL,leading_team_id=NULL,current_bid=0,
      current_player_state=p_result,updated_at=now()
  WHERE id=s.id;

  -- Next player in the current category.
  next_player := (arr->>0)::uuid;
  IF next_player IS NOT NULL THEN
    SELECT ap.id INTO next_ap_id
    FROM public.auction_players ap
    JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
    WHERE ap.tournament_id=p_tournament_id AND pr.player_id=next_player
    LIMIT 1;

    INSERT INTO public.auction_events(tournament_id,auction_player_id,status,current_bid,current_team_id,started_at)
    VALUES(p_tournament_id,next_ap_id,'live',public.auction_minimum_bid(next_player),NULL,now());

    UPDATE public.auction_players SET auction_status='live'
    WHERE id=next_ap_id;

    UPDATE public.auction_sessions
    SET current_player_id=next_player,current_bid=public.auction_minimum_bid(next_player),
        current_player_state='bidding',updated_at=now()
    WHERE id=s.id;
    RETURN jsonb_build_object('done',false,'player_id',next_player);
  END IF;

  -- Move to the next non-empty category.
  i := s.current_category_index;
  WHILE i+1 < jsonb_array_length(s.category_order) LOOP
    i:=i+1;
    next_cat:=(s.category_order->>i)::uuid;
    arr:=COALESCE(s.category_queues->(next_cat::text),'[]'::jsonb);
    next_player:=(arr->>0)::uuid;
    IF next_player IS NOT NULL THEN
      SELECT ap.id INTO next_ap_id
      FROM public.auction_players ap
      JOIN public.player_registrations pr ON pr.id=ap.player_registration_id
      WHERE ap.tournament_id=p_tournament_id AND pr.player_id=next_player
      LIMIT 1;

      INSERT INTO public.auction_events(tournament_id,auction_player_id,status,current_bid,current_team_id,started_at)
      VALUES(p_tournament_id,next_ap_id,'live',public.auction_minimum_bid(next_player),NULL,now());

      UPDATE public.auction_players SET auction_status='live'
      WHERE id=next_ap_id;

      UPDATE public.auction_sessions
      SET current_category_index=i,current_player_id=next_player,
          current_bid=public.auction_minimum_bid(next_player),current_player_state='bidding',updated_at=now()
      WHERE id=s.id;
      RETURN jsonb_build_object('done',false,'player_id',next_player,'category_id',next_cat);
    END IF;
  END LOOP;

  UPDATE public.auction_sessions
  SET status='completed',current_player_id=NULL,current_player_state='sold',updated_at=now()
  WHERE id=s.id;
  UPDATE public.auction_settings SET auction_status='completed' WHERE tournament_id=p_tournament_id;
  RETURN jsonb_build_object('done',true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_live_auction(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_live_auction_bid(UUID,UUID,NUMERIC,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finish_current_auction_player(UUID,TEXT) TO authenticated;


-- Securely bind a logged-in captain to the team selected by the admin.
CREATE OR REPLACE FUNCTION public.claim_captain_access(p_tournament_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  uid UUID := auth.uid();
  em TEXT := lower(COALESCE(auth.jwt()->>'email',''));
  inv public.captain_invites%ROWTYPE;
  pname TEXT;
  result_row public.captain_profiles%ROWTYPE;
BEGIN
  IF uid IS NULL OR em='' THEN RAISE EXCEPTION 'Please sign in first'; END IF;

  SELECT * INTO inv
  FROM public.captain_invites
  WHERE tournament_id=p_tournament_id AND active=TRUE AND lower(email)=em
  ORDER BY updated_at DESC
  LIMIT 1;

  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'This email is not registered as a captain for this tournament';
  END IF;

  SELECT COALESCE(display_name,full_name) INTO pname
  FROM public.players WHERE id=inv.player_id;

  INSERT INTO public.captain_profiles(user_id,tournament_id,email,display_name,team_id,updated_at)
  VALUES(uid,p_tournament_id,em,pname,inv.team_id,now())
  ON CONFLICT(user_id) DO UPDATE SET
    tournament_id=EXCLUDED.tournament_id,
    email=EXCLUDED.email,
    display_name=EXCLUDED.display_name,
    team_id=EXCLUDED.team_id,
    updated_at=now()
  RETURNING * INTO result_row;

  RETURN jsonb_build_object(
    'user_id',result_row.user_id,
    'tournament_id',result_row.tournament_id,
    'email',result_row.email,
    'display_name',result_row.display_name,
    'team_id',result_row.team_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_captain_access(UUID) TO authenticated;

-- Keep the existing signup trigger harmless for any previously-created captain accounts.
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
