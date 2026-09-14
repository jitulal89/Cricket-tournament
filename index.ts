import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) throw new Error("Administrator authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!serviceKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is not configured.");

    const adminClient = createClient(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: userData, error: userError } = await adminClient.auth.getUser(token);
    if (userError || !userData.user) throw new Error("Invalid administrator session.");

    const { data: adminProfile, error: adminError } = await adminClient
      .from("admin_profiles").select("id").eq("id", userData.user.id).maybeSingle();
    if (adminError || !adminProfile) throw new Error("Administrator access required.");

    const body = await req.json();
    const { tournament_id, team_id, player_id, email, password } = body;
    const cleanEmail = String(email || "").trim().toLowerCase();
    const cleanPassword = String(password || "");
    if (!tournament_id || !team_id || !player_id) throw new Error("Tournament, team and captain are required.");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) throw new Error("Enter a valid captain email.");
    if (cleanPassword.length < 8) throw new Error("Password must be at least 8 characters.");

    const { data: team, error: teamError } = await adminClient.from("teams").select("id,captain_id").eq("id", team_id).eq("tournament_id", tournament_id).maybeSingle();
    if (teamError || !team) throw new Error("Team not found.");
    if (team.captain_id !== player_id) throw new Error("Selected player is not the captain of this team.");

    const { data: player, error: playerError } = await adminClient.from("players").select("id,full_name,display_name").eq("id", player_id).maybeSingle();
    if (playerError || !player) throw new Error("Captain player not found.");

    const { data: existingInvite } = await adminClient.from("captain_invites").select("id,team_id").eq("tournament_id", tournament_id).eq("active", true).ilike("email", cleanEmail).maybeSingle();
    if (existingInvite && existingInvite.team_id !== team_id) throw new Error("This email is already assigned to another team.");

    // Create a new Auth user, or update the existing captain account password.
    let authUserId: string | null = null;
    const { data: created, error: createError } = await adminClient.auth.admin.createUser({ email: cleanEmail, password: cleanPassword, email_confirm: true, user_metadata: { role: "captain", tournament_id, team_id, player_id, display_name: player.display_name || player.full_name } });
    if (!createError && created.user) {
      authUserId = created.user.id;
    } else if (createError) {
      // If the email already has an Auth account, find it and reset its password.
      const { data: users } = await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const existing = users?.users?.find((u) => (u.email || "").toLowerCase() === cleanEmail);
      if (!existing) throw new Error(createError.message);
      authUserId = existing.id;
      const { error: updateError } = await adminClient.auth.admin.updateUserById(authUserId, { password: cleanPassword, email_confirm: true, user_metadata: { ...(existing.user_metadata || {}), role: "captain", tournament_id, team_id, player_id, display_name: player.display_name || player.full_name } });
      if (updateError) throw new Error(updateError.message);
    }

    const { error: inviteError } = await adminClient.from("captain_invites").upsert({ tournament_id, team_id, player_id, email: cleanEmail, active: true, updated_at: new Date().toISOString() }, { onConflict: "tournament_id,team_id" });
    if (inviteError) throw new Error(inviteError.message);

    const { error: profileError } = await adminClient.from("captain_profiles").upsert({ user_id: authUserId, tournament_id, email: cleanEmail, display_name: player.display_name || player.full_name, team_id, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
    if (profileError) throw new Error(profileError.message);

    return new Response(JSON.stringify({ ok: true, user_id: authUserId }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: err instanceof Error ? err.message : "Unexpected error" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
