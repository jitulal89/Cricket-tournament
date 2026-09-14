V13 FIX - FINISH CURRENT AUCTION PLAYER

1. Upload all files to GitHub, replacing the existing V6 files.
2. In Supabase SQL Editor, run:
   006_fix_finish_current_auction_player.sql
3. The Admin Auction page now calls:
   finish_current_auction_player(p_tournament, p_result)
   which matches the actual database function signature.
4. Do NOT run Start Auction again if the current auction is already LIVE.
5. Refresh Admin and Captain auction pages after the SQL is applied.

This fix handles:
- Sell player
- Unsold player
- Team purse deduction
- Add sold player to auction squad
- Auction result recording
- Current auction event completion
- Automatic next player
- Auction completion when no players remain
