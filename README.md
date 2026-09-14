# Cricket Tournament Platform V5

## Important fixes
- Live auction RPCs now use the existing `auction_events`, `auction_bids`, and `auction_results` columns.
- No `auction_bids.tournament_id` or `auction_bids.player_id` assumptions.
- Start Auction creates an auction event for the current `auction_player`.
- Bids are stored against `auction_event_id`.
- Results are stored using `auction_event_id`, `auction_player_id`, `result`, `team_id`, and `final_price`.
- Empty categories are skipped automatically.
- Captain login setup is now inside **Pre-Auction Setup → Select Captains**.
- Admin enters the captain email and taps **Create Captain Login**.
- Captain signs in using a secure one-time email link; no service-role key is placed in the website.
- Live bid realtime subscription no longer filters on the non-existent `auction_bids.tournament_id` column.

## Supabase
1. Open Supabase SQL Editor.
2. Run `005_live_auction_and_captain_login.sql` once.
3. If an older V4 migration was partially run, this script recreates the affected functions/policies safely.
4. Do not put a Supabase service-role/secret key into the website.

## Website
Upload/replace the files in your GitHub Pages repository with this package.


## Captain email/password accounts

Captain accounts are created by the admin during Pre-Auction Setup. The website calls the Supabase Edge Function `create-captain-account`; the Supabase service-role key must be configured as an Edge Function secret and must never be placed in browser code.

Deploy the function from the `supabase/functions/create-captain-account` folder, or create the function in the Supabase Dashboard Edge Functions editor. Configure `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` as server-side secrets.
