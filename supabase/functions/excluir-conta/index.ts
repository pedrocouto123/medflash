// =====================================================================
// Pulse Medcards — Exclusão de conta pelo próprio aluno (LGPD, art. 18, VI)
// Apaga a conta pelo Supabase Auth; progresso, revisões, favoritos, decks pessoais,
// uso e tela conectada saem em cascata. Fica só o registro mínimo de pagamento
// (e-mail, plano, datas), sem vínculo com a conta, para obrigações legais.
// Exige login (verify_jwt) e a palavra EXCLUIR. Bloqueia se houver renovação ativa na Kiwify.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = {
  "Access-Control-Allow-Origin": "*", // autenticação por token no cabeçalho, sem cookies
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-tela",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resposta = (status: number, corpo: Record<string, unknown>) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return resposta(405, { erro: "use POST" });

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user }, error: eUser } = await admin.auth.getUser(token);
  if (eUser || !user) return resposta(401, { erro: "Sessão expirada. Entre de novo e tente outra vez." });

  let corpo: any = {};
  try { corpo = await req.json(); } catch { /* corpo vazio */ }
  if (String(corpo?.confirmacao ?? "").trim().toUpperCase() !== "EXCLUIR") return resposta(400, { erro: "Digite EXCLUIR para confirmar." });

  const email = String(user.email ?? "").toLowerCase();
  const { data: renovando } = await admin.from("kiwify_assinaturas").select("id")
    .eq("email", email).in("status", ["ativa", "atrasada"]).gt("expira_em", new Date().toISOString()).limit(1);
  if (renovando?.length) {
    return resposta(409, { erro: "Sua assinatura ainda está com renovação ativa. Cancele a renovação na Kiwify antes de excluir a conta; o acesso continua até o fim do período já pago." });
  }

  // Registro de pagamento fica sem vínculo e sem nome
  const { error: e1 } = await admin.from("assinaturas").update({ user_id: null, nome: null }).eq("user_id", user.id);
  const { error: e2 } = await admin.from("assinaturas").update({ user_id: null, nome: null }).eq("email", email);
  if (e1 || e2) { console.error(e1?.message ?? e2?.message); return resposta(500, { erro: "Não foi possível excluir agora. Tente de novo em instantes." }); }

  const { error: e3 } = await admin.auth.admin.deleteUser(user.id);
  if (e3) { console.error(e3.message); return resposta(500, { erro: "Não foi possível excluir agora. Tente de novo em instantes." }); }
  console.log("conta excluída a pedido do titular");
  return resposta(200, { ok: true });
});
