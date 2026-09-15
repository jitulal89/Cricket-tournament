
const SUPABASE_URL="https://jauulapjawbusltlqyau.supabase.co";
const SUPABASE_PUBLISHABLE_KEY="sb_publishable_QkA-HpPACdhHRlA7DKYtFA_GvDjT7Qi";
const sb=supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);

function esc(v=""){return String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]))}
function qs(k){return new URLSearchParams(location.search).get(k)||""}
function go(url){location.href=url}
function msg(text,type="ok"){return `<div class="msg ${type}">${esc(text)}</div>`}
function slugify(v=""){return String(v).trim().toLowerCase().replace(/[^a-z0-9-]+/g,"-").replace(/^-|-$/g,"")}
function money(v){return "₹"+Number(v||0).toLocaleString("en-IN")}
function fmtDate(v){if(!v)return "—";return new Date(v).toLocaleString("en-IN",{dateStyle:"medium",timeStyle:"short"})}

async function isAdmin(){
 const {data:{user}}=await sb.auth.getUser();
 if(!user)return false;
 const {data}=await sb.from("admin_profiles").select("id,role").eq("id",user.id).maybeSingle();
 return !!data;
}
async function requireAdmin(){
 if(!(await isAdmin())){location.href="admin.html";return false}
 return true;
}
async function logout(){await sb.auth.signOut();location.href="index.html"}
async function uploadLogo(file,tournamentId){
 if(!file)return null;
 const {data:{user}}=await sb.auth.getUser();
 if(!user)throw new Error("Please sign in as an administrator.");
 const ext=(file.name.split(".").pop()||"png").toLowerCase().replace(/[^a-z0-9]/g,"")||"png";
 const path=`${user.id}/${tournamentId}/${Date.now()}.${ext}`;
 const {error}=await sb.storage.from("tournament-logos").upload(path,file,{upsert:true,contentType:file.type||"image/png"});
 if(error)throw error;
 return sb.storage.from("tournament-logos").getPublicUrl(path).data.publicUrl;
}
async function setNav(){
 const el=document.getElementById("nav");
 if(!el)return;
 const {data:{session}}=await sb.auth.getSession();
 el.innerHTML=session
 ?`<a href="index.html">Home</a><a href="admin-dashboard.html">Admin</a><button onclick="logout()">Logout</button>`
 :`<a href="index.html">Home</a><a href="admin.html">Admin Login</a>`;
}
async function getTournament(slug){
 const raw=String(slug||"").trim();
 if(!raw)throw new Error("Tournament slug is required.");
 const normalized=slugify(raw);
 // V13.1: resolve by slug safely without maybeSingle(), then fall back to name.
 let q=await sb.from("tournaments").select("*").eq("slug",raw).limit(1);
 if(q.error)throw q.error;
 let data=q.data?.[0]||null;
 if(!data && normalized && normalized!==raw){
   q=await sb.from("tournaments").select("*").eq("slug",normalized).limit(1);
   if(q.error)throw q.error;
   data=q.data?.[0]||null;
 }
 if(!data){
   q=await sb.from("tournaments").select("*").ilike("name",raw).limit(1);
   if(q.error)throw q.error;
   data=q.data?.[0]||null;
 }
 if(!data)throw new Error(`Tournament not found for "${raw}". Please use the tournament slug shown on the public tournament page.`);
 return data;
}
