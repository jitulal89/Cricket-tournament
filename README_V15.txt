CRICKET TOURNAMENT PLATFORM V15

Fixes:
- Fixed Admin Live Auction schema-cache error caused by trying to use auction_players -> players as a direct relationship.
- Admin auction now follows auction_players -> player_registrations -> players when loading the last sold player.
- Current player loading already uses the correct player_registrations -> players relationship.
- Updated app.js cache-busting version to v15.

No new SQL migration is required for this fix.
