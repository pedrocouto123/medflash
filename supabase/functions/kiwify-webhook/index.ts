// =====================================================================
// Pulse Medcards — Webhook da Kiwify
// Recebe as notificações de venda/assinatura (planos mensal e anual) e libera ou corta o acesso.
//
// Regras:
//   - Pagamento aprovado/renovado: acesso até o FIM DO DIA do próximo vencimento (horário de Brasília).
//     Vence dia 10 -> o acesso cai à 00:00 do dia 11 se a renovação não for paga.
//   - Atrasada ou cancelada: mantém a data já paga (não estende).
//   - Reembolso ou chargeback: corta na hora e desconecta os aparelhos.
//   - Mensal e anual ao mesmo tempo (migração): vale a data mais distante.
//
// Tokens dos webhooks: segredo KIWIFY_TOKEN e/ou public.config chave 'kiwify_tokens'
// (vários separados por vírgula: um por webhook criado na Kiwify).
// A verificação de JWT fica desativada: a segurança é a assinatura HMAC da Kiwify.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const APP_URL_ENV = (Deno.env.get("APP_URL") ?? "").replace(/\/$/, "");

// ---------- utilidades ----------
async function hmacSha1Hex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function igualSeguro(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
// Lê um campo tolerando variações de maiúsculas/minúsculas no payload
function campo(obj: any, ...nomes: string[]): any {
  if (!obj || typeof obj !== "object") return undefined;
  for (const n of nomes) {
    if (obj[n] !== undefined && obj[n] !== null) return obj[n];
    const achado = Object.keys(obj).find((k) => k.toLowerCase() === n.toLowerCase());
    if (achado && obj[achado] !== undefined && obj[achado] !== null) return obj[achado];
  }
  return undefined;
}
const resposta = (status: number, corpo: Record<string, unknown>) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

// Data (AAAA-MM-DD) no horário de Brasília
function diaBrasilia(v: unknown): string | null {
  if (!v) return null;
  const s = String(v).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const d = new Date(s.replace(" ", "T"));
  if (isNaN(d.getTime())) return null;
  return new Date(d.getTime() - 3 * 3600000).toISOString().slice(0, 10);
}
// Fim do dia do vencimento = 00:00 do dia seguinte em Brasília (UTC-3)
function fimDoDia(dia: string): string {
  const d = new Date(`${dia}T00:00:00-03:00`);
  return new Date(d.getTime() + 86400000).toISOString();
}
function somarPeriodo(plano: string): string {
  const d = new Date(Date.now() - 3 * 3600000);
  if (plano === "anual") d.setUTCFullYear(d.getUTCFullYear() + 1); else d.setUTCMonth(d.getUTCMonth() + 1);
  return fimDoDia(d.toISOString().slice(0, 10));
}

async function tokens(): Promise<string[]> {
  const lista = (Deno.env.get("KIWIFY_TOKEN") ?? "").split(",");
  const { data } = await supabase.from("config").select("valor").eq("chave", "kiwify_tokens").maybeSingle();
  if (data?.valor) lista.push(...String(data.valor).split(","));
  return lista.map((t) => t.trim()).filter(Boolean);
}
async function urlDoApp(): Promise<string> {
  if (APP_URL_ENV) return APP_URL_ENV;
  const { data } = await supabase.from("config").select("valor").eq("chave", "app_url").maybeSingle();
  return String(data?.valor ?? "").replace(/\/$/, "");
}

// Conta de quem pagou: usa a existente (criada no teste grátis) ou envia convite
async function garantirUsuario(email: string, nome: string): Promise<string | null> {
  const { data: id } = await supabase.rpc("id_por_email", { p_email: email });
  if (id) return id as string;
  const app = await urlDoApp();
  const { data: convite, error } = await supabase.auth.admin.inviteUserByEmail(email, {
    data: { nome }, redirectTo: app ? `${app}/?definir=1` : undefined,
  });
  if (error) console.error("Falha ao convidar:", error.message);
  return convite?.user?.id ?? null;
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta(405, { erro: "use POST" });
  const corpo = await req.text();

  // 1) Autenticidade: HMAC-SHA1 do corpo com o token do webhook, enviado em ?signature=
  const lista = await tokens();
  if (!lista.length) return resposta(500, { erro: "token da Kiwify não configurado" });
  const assinatura = (new URL(req.url).searchParams.get("signature") ?? "").toLowerCase();
  let valida = false;
  for (const t of lista) if (assinatura && igualSeguro(assinatura, await hmacSha1Hex(t, corpo))) valida = true;
  if (!valida) return resposta(401, { erro: "assinatura inválida" });

  let p: any;
  try { p = JSON.parse(corpo); } catch { return resposta(400, { erro: "JSON inválido" }); }
  if (p?.order && typeof p.order === "object" && !campo(p, "Customer")) p = p.order;

  const evento = String(campo(p, "webhook_event_type") ?? "").toLowerCase();
  const statusPedido = String(campo(p, "order_status") ?? "").toLowerCase();
  const cliente = campo(p, "Customer", "customer") ?? {};
  const email = String(campo(cliente, "email") ?? "").trim().toLowerCase();
  const nome = String(campo(cliente, "full_name", "name", "first_name") ?? "").trim();
  const assin = campo(p, "Subscription", "subscription") ?? {};
  const planoK = campo(assin, "plan") ?? {};
  const produto = campo(p, "Product", "product") ?? {};
  const idAssinatura = String(campo(p, "subscription_id") ?? campo(assin, "id") ?? "") || null;
  const idPedido = String(campo(p, "order_id", "order_ref") ?? "") || null;
  const proximo = diaBrasilia(campo(assin, "next_payment", "charges_next_payment", "next_charge"));
  const textoPlano = [campo(planoK, "frequency"), campo(planoK, "name"), campo(produto, "product_name", "name")].map((x) => String(x ?? "")).join(" ").toLowerCase();
  const plano = /year|anual|annual|12 ?mes/.test(textoPlano) ? "anual" : "mensal";

  await supabase.from("webhook_log").insert({ evento: evento || statusPedido, email, payload: p });
  if (!email) return resposta(200, { ok: true, ignorado: "sem e-mail do cliente" });
  const chave = idAssinatura ?? idPedido ?? `${email}:${plano}`;

  // 2) Evento -> situação desta assinatura
  const aprovado = ["order_approved", "compra_aprovada", "subscription_renewed"].includes(evento) || (!evento && statusPedido === "paid");
  const reembolso = ["order_refunded", "compra_reembolsada", "chargeback", "order_chargedback"].includes(evento) || ["refunded", "chargedback"].includes(statusPedido);
  const { data: anterior } = await supabase.from("kiwify_assinaturas").select("expira_em").eq("id", chave).maybeSingle();

  let status: string, expira: string | null;
  if (reembolso) { status = "reembolsada"; expira = new Date().toISOString(); }
  else if (aprovado) { status = "ativa"; expira = proximo ? fimDoDia(proximo) : somarPeriodo(plano); }
  else if (evento === "subscription_canceled") { status = "cancelada"; expira = anterior?.expira_em ?? (proximo ? fimDoDia(proximo) : new Date().toISOString()); }
  else if (evento === "subscription_late") { status = "atrasada"; expira = anterior?.expira_em ?? (proximo ? fimDoDia(proximo) : new Date().toISOString()); }
  else return resposta(200, { ok: true, ignorado: evento || statusPedido }); // pix/boleto gerado, carrinho abandonado etc.

  // 3) Grava e consolida
  const { error } = await supabase.from("kiwify_assinaturas").upsert({ id: chave, email, plano, status, expira_em: expira, atualizado_em: new Date().toISOString() });
  if (error) { console.error(error.message); return resposta(500, { erro: "falha ao gravar" }); } // a Kiwify reenvia
  const { error: e2 } = await supabase.rpc("recalcular_assinatura", { p_email: email });
  if (e2) { console.error(e2.message); return resposta(500, { erro: "falha ao consolidar" }); }

  if (status === "ativa") {
    const uid = await garantirUsuario(email, nome);
    if (uid) await supabase.from("assinaturas").update({ user_id: uid, ...(nome ? { nome } : {}), kiwify_pedido: idPedido }).eq("email", email);
  }
  if (status === "reembolsada") {
    const { data: a } = await supabase.from("assinaturas").select("user_id, status").eq("email", email).maybeSingle();
    if (a?.user_id && a.status === "reembolsada") await supabase.from("dispositivos").delete().eq("user_id", a.user_id);
  }
  return resposta(200, { ok: true, email, plano, status, expira_em: expira });
});
