// =====================================================================
// Pulse Medcards — Recebe decks importados pelo GitHub Actions
//
// Segurança: só aceita chamadas com o token OIDC que o próprio GitHub
// emite para o workflow "Importar decks" deste repositório, na branch main.
// Nenhuma chave secreta fica no GitHub.
//
// Ações (POST JSON):
//   { acao: "midia", chave, tipo, base64 }        -> envia uma imagem ao Storage
//   { acao: "decks", nomes: [...], oculto }        -> cria/atualiza decks, devolve ids
//   { acao: "cards", linhas: [...] }               -> cria/atualiza cards (por anki_card_id)
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";

const REPOSITORIO = "pedrocouto123/medflash";
const AUDIENCIA = "pulse-medcards-importar";
const JWKS = createRemoteJWKSet(new URL("https://token.actions.githubusercontent.com/.well-known/jwks"));

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const resposta = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

async function autorizado(req: Request): Promise<string | null> {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return "sem token";
  try {
    const { payload } = await jwtVerify(token, JWKS, {
      issuer: "https://token.actions.githubusercontent.com",
      audience: AUDIENCIA,
    });
    if (payload.repository !== REPOSITORIO) return "repositório não autorizado";
    if (payload.ref !== "refs/heads/main") return "branch não autorizada";
    return null;
  } catch (e) {
    return "token inválido: " + (e as Error).message;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta(405, { erro: "use POST" });
  const negado = await autorizado(req);
  if (negado) return resposta(401, { erro: negado });

  let p: any;
  try { p = await req.json(); } catch { return resposta(400, { erro: "JSON inválido" }); }

  if (p.acao === "midia") {
    if (!/^[a-f0-9]{40}\.[a-z0-9]{1,5}$/.test(String(p.chave))) return resposta(400, { erro: "chave inválida" });
    const bytes = Uint8Array.from(atob(String(p.base64)), (c) => c.charCodeAt(0));
    const { error } = await supabase.storage.from("midia").upload(p.chave, bytes, {
      contentType: String(p.tipo || "application/octet-stream"), upsert: true, cacheControl: "31536000",
    });
    if (error) return resposta(500, { erro: error.message });
    return resposta(200, { url: supabase.storage.from("midia").getPublicUrl(p.chave).data.publicUrl });
  }

  if (p.acao === "decks") {
    const nomes = (p.nomes ?? []).map(String).filter(Boolean);
    const { data, error } = await supabase.from("decks")
      .upsert(nomes.map((nome: string) => ({ nome, ...(p.oculto ? { publicado: false } : {}) })), { onConflict: "nome" })
      .select("id, nome");
    if (error) return resposta(500, { erro: error.message });
    return resposta(200, { decks: data });
  }

  if (p.acao === "cards") {
    const linhas = (p.linhas ?? []).map((c: any) => ({
      anki_card_id: Number(c.anki_card_id), deck_id: String(c.deck_id),
      frente: String(c.frente), verso: String(c.verso),
      tags: Array.isArray(c.tags) ? c.tags.map(String) : [], ordem: Number(c.ordem) || 0,
      atualizado_em: new Date().toISOString(),
    }));
    const { error } = await supabase.from("cards").upsert(linhas, { onConflict: "anki_card_id" });
    if (error) return resposta(500, { erro: error.message });
    return resposta(200, { gravados: linhas.length });
  }

  return resposta(400, { erro: "ação desconhecida" });
});
