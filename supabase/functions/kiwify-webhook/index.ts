// =====================================================================
// Pulse Medcards — Webhook da Kiwify
// Recebe as notificações de venda/assinatura e libera ou bloqueia o acesso.
//
// Segredos necessários (definidos automaticamente pelo GitHub Actions,
// ou manualmente em Supabase > Edge Functions > Secrets):
//   KIWIFY_TOKEN   -> o "token" exibido ao criar o webhook na Kiwify
//   APP_URL        -> (opcional) endereço do app, ex.: https://medflash.vercel.app
//                     Se vazio, usa public.config chave 'app_url'.
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente.)
//
// IMPORTANTE: a verificação de JWT fica desativada (supabase/config.toml),
// porque a Kiwify não envia token do Supabase.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const KIWIFY_TOKEN = Deno.env.get("KIWIFY_TOKEN") ?? "";
const APP_URL = (Deno.env.get("APP_URL") ?? "").replace(/\/$/, "");

// ---------- utilidades ----------
async function hmacSha1Hex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
  );
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

function data(v: unknown): string | null {
  if (!v) return null;
  const d = new Date(String(v).replace(" ", "T"));
  return isNaN(d.getTime()) ? null : d.toISOString();
}

function somarDias(dias: number): string {
  return new Date(Date.now() + dias * 86400000).toISOString();
}

function resposta(status: number, corpo: Record<string, unknown>) {
  return new Response(JSON.stringify(corpo), {
    status, headers: { "Content-Type": "application/json" },
  });
}

// Duração aproximada do plano, usada quando a Kiwify não informa a próxima cobrança
function diasDoPlano(freq: string | undefined): number {
  const f = (freq ?? "").toLowerCase();
  if (f.includes("year") || f.includes("anual")) return 366;
  if (f.includes("semi")) return 184;
  if (f.includes("quarter") || f.includes("trimes")) return 93;
  if (f.includes("week") || f.includes("seman")) return 8;
  return 32; // mensal (padrão)
}

// Endereço do app: segredo APP_URL ou, se vazio, public.config (chave 'app_url')
let _urlApp: string | null = null;
async function urlDoApp(): Promise<string> {
  if (APP_URL) return APP_URL;
  if (_urlApp !== null) return _urlApp;
  const { data } = await supabase.from("config").select("valor").eq("chave", "app_url").maybeSingle();
  _urlApp = (data?.valor ?? "").replace(/\/$/, "");
  return _urlApp;
}

// Cria a conta do aluno (se ainda não existir) e envia o e-mail de convite
async function garantirUsuario(email: string, nome: string): Promise<string | null> {
  const { data: existente } = await supabase.from("assinaturas")
    .select("user_id").eq("email", email).maybeSingle();
  if (existente?.user_id) return existente.user_id;

  const app = await urlDoApp();
  const { data: convite, error } = await supabase.auth.admin.inviteUserByEmail(email, {
    data: { nome },
    redirectTo: app ? `${app}/?definir=1` : undefined,
  });
  if (!error && convite?.user) return convite.user.id;

  // Já existe usuário com esse e-mail (ex.: assinante que voltou): procura o id
  const msg = (error?.message ?? "").toLowerCase();
  if (msg.includes("already") || msg.includes("registered") || msg.includes("exists")) {
    for (let pagina = 1; pagina <= 50; pagina++) {
      const { data: lista } = await supabase.auth.admin.listUsers({ page: pagina, perPage: 1000 });
      const u = lista?.users?.find((x) => x.email?.toLowerCase() === email);
      if (u) return u.id;
      if (!lista || lista.users.length < 1000) break;
    }
  }
  console.error("Falha ao criar/convidar usuário:", error?.message);
  return null;
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta(405, { erro: "use POST" });

  const corpo = await req.text();

  // 1) Autenticidade: a Kiwify assina o corpo com HMAC-SHA1 usando o token do webhook
  //    e envia o resultado no parâmetro ?signature= da URL.
  if (!KIWIFY_TOKEN) return resposta(500, { erro: "KIWIFY_TOKEN não configurado" });
  const assinatura = new URL(req.url).searchParams.get("signature") ?? "";
  const esperado = await hmacSha1Hex(KIWIFY_TOKEN, corpo);
  if (!assinatura || !igualSeguro(assinatura.toLowerCase(), esperado)) {
    return resposta(401, { erro: "assinatura inválida" });
  }

  let p: any;
  try { p = JSON.parse(corpo); } catch { return resposta(400, { erro: "JSON inválido" }); }
  // Alguns envios vêm embrulhados em { order: {...} }
  if (p?.order && typeof p.order === "object" && !campo(p, "Customer")) p = p.order;

  const evento = String(campo(p, "webhook_event_type") ?? "").toLowerCase();
  const statusPedido = String(campo(p, "order_status") ?? "").toLowerCase();
  const cliente = campo(p, "Customer", "customer") ?? {};
  const email = String(campo(cliente, "email") ?? "").trim().toLowerCase();
  const nome = String(campo(cliente, "full_name", "name", "first_name") ?? "").trim();
  const assin = campo(p, "Subscription", "subscription") ?? {};
  const plano = campo(assin, "plan") ?? {};
  const idAssinatura = String(campo(p, "subscription_id") ?? campo(assin, "id") ?? "") || null;
  const idPedido = String(campo(p, "order_id", "order_ref") ?? "") || null;
  const proxCobranca = data(campo(assin, "next_payment", "charges_next_payment", "next_charge"));
  const nomePlano = String(campo(plano, "name") ?? campo(campo(p, "Product") ?? {}, "product_name") ?? "") || null;
  const freq = String(campo(plano, "frequency") ?? "");

  await supabase.from("webhook_log").insert({ evento: evento || statusPedido, email, payload: p });

  if (!email) return resposta(200, { ok: true, ignorado: "sem e-mail do cliente" });

  // 2) Traduz o evento da Kiwify em situação de acesso
  let status: string | null = null;
  let expira: string | null = null;

  const aprovado = ["order_approved", "compra_aprovada", "subscription_renewed"].includes(evento)
    || (!evento && statusPedido === "paid");
  const reembolso = ["order_refunded", "compra_reembolsada", "chargeback"].includes(evento)
    || ["refunded", "chargedback"].includes(statusPedido);

  if (reembolso) {
    status = "reembolsada"; expira = new Date().toISOString();              // bloqueia na hora
  } else if (aprovado) {
    // Vale até a próxima cobrança + 1 dia de folga (cobre fuso horário e atraso na confirmação)
    status = "ativa";
    expira = proxCobranca
      ? new Date(new Date(proxCobranca).getTime() + 86400000).toISOString()
      : somarDias(diasDoPlano(freq) + 1);
  } else if (evento === "subscription_canceled") {
    status = "cancelada"; expira = proxCobranca;                             // mantém até o fim do período pago
  } else if (evento === "subscription_late") {
    status = "atrasada"; expira = proxCobranca ?? new Date().toISOString();  // carência definida em config
  } else {
    // boleto/pix gerado, carrinho abandonado, compra recusada: nada a fazer
    return resposta(200, { ok: true, ignorado: evento || statusPedido });
  }

  // 3) Cria a conta na primeira compra
  let userId: string | null = null;
  if (status === "ativa") userId = await garantirUsuario(email, nome);

  // 4) Grava a assinatura
  const { data: anterior } = await supabase.from("assinaturas")
    .select("expira_em, user_id").eq("email", email).maybeSingle();

  // Cancelamento sem data informada: preserva a data já conhecida
  if (status === "cancelada" && !expira) expira = anterior?.expira_em ?? new Date().toISOString();

  const registro: Record<string, unknown> = {
    email, status, expira_em: expira, atualizado_em: new Date().toISOString(),
  };
  if (nome) registro.nome = nome;
  if (idAssinatura) registro.kiwify_assinatura = idAssinatura;
  if (idPedido) registro.kiwify_pedido = idPedido;
  if (nomePlano) registro.plano = nomePlano;
  if (userId ?? anterior?.user_id) registro.user_id = userId ?? anterior?.user_id;

  const { error } = await supabase.from("assinaturas").upsert(registro, { onConflict: "email" });
  if (error) {
    console.error("Erro ao gravar assinatura:", error.message);
    return resposta(500, { erro: "falha ao gravar" }); // a Kiwify tentará reenviar
  }

  // Aluno que perdeu acesso é desconectado de todos os aparelhos
  if (status === "reembolsada" && registro.user_id) {
    await supabase.from("dispositivos").delete().eq("user_id", registro.user_id as string);
  }

  return resposta(200, { ok: true, email, status, expira_em: expira });
});
