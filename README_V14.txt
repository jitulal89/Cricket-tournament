V14 changes
- Same-device captain testing: use captain-login.html?session=team-a/team-b/team-c/etc. Each session has isolated Supabase auth storage.
- Admin and Captain use auction_sessions.current_auction_player_id as the source of truth.
- Rich auction player card: photo placeholder, role, batting/bowling style, CricHeroes stats placeholders, profile link.
- Admin shows current leading team and last sold player/team/price.
- Run 007_v14_player_profile_fields.sql once in Supabase SQL Editor.
