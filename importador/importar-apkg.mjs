#!/usr/bin/env node
// =====================================================================
// Pulse Medcards — Importador de decks do Anki (.apkg)
//
// Uso:
//   node importar-apkg.mjs <arquivo.apkg> [mais arquivos...] [opções]
//
// Opções:
//   --previa            Só gera uma página de pré-visualização (previa.html), não envia nada
//   --prefixo "Nome"    Coloca os decks importados dentro de uma área. Ex.: --prefixo "Pediatria"
//   --oculto            Importa sem publicar (os alunos não veem até você publicar)
//   --via-funcao        Envia pela função "importar" do Supabase (usado pelo GitHub Actions,
//                       sem precisar da service_role key)
//
// Antes de exportar do Anki: Arquivo > Exportar > "Pacote de baralho Anki (.apkg)",
// marque "Incluir mídia" e "Suporte a versões antigas do Anki".
// Reimportar o mesmo deck ATUALIZA os cards (não duplica e não apaga o progresso dos alunos).
// =====================================================================
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import AdmZip from "adm-zip";
import initSqlJs from "sql.js";
import {
  renderTemplate, numerosCloze, midiasReferenciadas, trocarMidias, stripHtml,
} from "./anki-render.mjs";

// ---------- argumentos ----------
const args = process.argv.slice(2);
const opcoes = { previa: false, prefixo: "", oculto: false, viaFuncao: false };
const arquivos = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--previa") opcoes.previa = true;
  else if (a === "--oculto") opcoes.oculto = true;
  else if (a === "--via-funcao") opcoes.viaFuncao = true;
  else if (a === "--prefixo") opcoes.prefixo = (args[++i] ?? "").trim();
  else arquivos.push(a);
}
if (!arquivos.length) {
  console.log('Uso: node importar-apkg.mjs <arquivo.apkg> [--previa] [--prefixo "Área"] [--oculto]');
  process.exit(1);
}

const MIME = {
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif",
  webp: "image/webp", svg: "image/svg+xml", bmp: "image/bmp", avif: "image/avif",
};

// ---------- leitura do .apkg ----------
async function lerApkg(caminho) {
  const zip = new AdmZip(caminho);
  const entradas = Object.fromEntries(zip.getEntries().map((e) => [e.entryName, e]));

  const colecao = entradas["collection.anki21"] ?? entradas["collection.anki2"];
  if (entradas["collection.anki21b"] && !entradas["collection.anki21"]) {
    throw new Error(
      `"${path.basename(caminho)}" foi exportado no formato novo do Anki.\n` +
      `   Exporte de novo marcando a opção "Suporte a versões antigas do Anki".`,
    );
  }
  if (!colecao) throw new Error(`"${path.basename(caminho)}" não parece ser um arquivo .apkg válido.`);

  const SQL = await initSqlJs();
  const db = new SQL.Database(colecao.getData());
  const umValor = (sql) => db.exec(sql)[0]?.values?.[0]?.[0];

  const modelos = JSON.parse(umValor("select models from col") || "{}");
  const decks = JSON.parse(umValor("select decks from col") || "{}");

  // Mídia: arquivo "media" = {"0": "imagem.jpg", ...}
  let mapaMidia = {};
  if (entradas["media"]) {
    try { mapaMidia = JSON.parse(entradas["media"].getData().toString("utf8") || "{}"); }
    catch { throw new Error("Não consegui ler a lista de mídias. Exporte com \"Suporte a versões antigas do Anki\"."); }
  }
  const midias = {}; // nome original -> Buffer
  for (const [num, nome] of Object.entries(mapaMidia)) {
    if (entradas[num]) midias[nome] = () => entradas[num].getData();
  }

  const linhas = db.exec(`
    select c.id, c.ord, c.did, c.queue, n.id, n.mid, n.flds, n.tags
    from cards c join notes n on n.id = c.nid
    order by c.did, n.id, c.ord`)[0]?.values ?? [];

  const cards = [];
  let ignorados = 0;
  for (const [cid, ord, did, queue, nid, mid, flds, tags] of linhas) {
    const modelo = modelos[String(mid)];
    if (!modelo) { ignorados++; continue; }
    const valores = String(flds).split("\x1f");
    const campos = {};
    modelo.flds.forEach((f, i) => { campos[f.name] = valores[i] ?? ""; });

    const ehCloze = modelo.type === 1;
    const template = ehCloze ? modelo.tmpls[0] : modelo.tmpls.find((t) => t.ord === ord) ?? modelo.tmpls[ord];
    if (!template) { ignorados++; continue; }

    const nomeDeck = decks[String(did)]?.name ?? "Sem nome";
    const listaTags = String(tags).trim().split(/\s+/).filter(Boolean);
    const ctx = {
      cloze: ehCloze ? ord + 1 : 0,
      tags: listaTags, deck: nomeDeck, card: template.name,
    };
    const frente = renderTemplate(template.qfmt, campos, { ...ctx, lado: "q" });
    const verso = renderTemplate(template.afmt, campos, { ...ctx, lado: "a", frontSide: frente });

    // Card cloze cujo número não existe mais no texto (Anki o deixaria vazio)
    if (ehCloze && !Object.values(campos).some((v) => numerosCloze(v).includes(ord + 1))) { ignorados++; continue; }
    if (!stripHtml(frente) && !/<img/i.test(frente)) { ignorados++; continue; }

    cards.push({
      anki_card_id: Number(cid), deck: nomeDeck, frente, verso,
      tags: listaTags, suspenso: queue === -1,
    });
  }
  db.close();
  return { cards, midias, ignorados };
}

function nomeFinal(deck) {
  const limpo = deck === "Default" ? "Geral" : deck;
  return opcoes.prefixo ? `${opcoes.prefixo}::${limpo}` : limpo;
}

function chaveMidia(nome) {
  const ext = (nome.split(".").pop() || "bin").toLowerCase().replace(/[^a-z0-9]/g, "");
  return `${crypto.createHash("sha1").update(nome).digest("hex")}.${ext}`;
}

// ---------- prévia local ----------
function gerarPrevia(todos, midias) {
  const pasta = path.resolve("previa");
  fs.mkdirSync(path.join(pasta, "midia"), { recursive: true });
  const mapa = {};
  for (const nome of new Set(todos.flatMap((c) => [...midiasReferenciadas(c.frente), ...midiasReferenciadas(c.verso)]))) {
    const ler = midias[nome] ?? midias[decodeURIComponent(nome)];
    if (!ler) continue;
    const chave = chaveMidia(nome);
    fs.writeFileSync(path.join(pasta, "midia", chave), ler());
    mapa[nome] = `midia/${chave}`;
  }
  const porDeck = {};
  for (const c of todos) (porDeck[nomeFinal(c.deck)] ??= []).push(c);
  const esc = (s) => s.replace(/[&<>]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[ch]));
  const blocos = Object.entries(porDeck).map(([deck, cs]) => `
    <h2>${esc(deck)} <small>${cs.length} cards</small></h2>
    ${cs.slice(0, 30).map((c, i) => `
      <div class="par"><div class="lado"><b>Frente ${i + 1}</b>${trocarMidias(c.frente, mapa)}</div>
      <div class="lado"><b>Verso</b>${trocarMidias(c.verso, mapa)}</div></div>`).join("")}
    ${cs.length > 30 ? `<p><i>… e mais ${cs.length - 30} cards</i></p>` : ""}`).join("");
  fs.writeFileSync(path.join(pasta, "previa.html"), `<!doctype html><meta charset="utf-8">
<title>Prévia da importação</title>
<style>body{font:15px system-ui;max-width:1100px;margin:24px auto;padding:0 16px;color:#1d2433}
h2{border-bottom:2px solid #0e7c6b;padding-bottom:4px;margin-top:40px}small{color:#667;font-weight:400}
.par{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:10px 0}
.lado{border:1px solid #d8dee8;border-radius:8px;padding:12px;background:#fff;overflow:auto}
.lado b{display:block;font-size:12px;color:#667;margin-bottom:6px}
.cloze{color:#0e7c6b;font-weight:700}img{max-width:100%}hr{border:0;border-top:1px dashed #ccd}</style>
<h1>Prévia da importação</h1><p>${todos.length} cards em ${Object.keys(porDeck).length} decks. Mostrando até 30 por deck.</p>${blocos}`);
  return path.join(pasta, "previa.html");
}

// ---------- destino: Supabase direto (service_role) ou função "importar" (GitHub Actions) ----------
async function destinoDireto() {
  const { config } = await import("dotenv");
  config();
  const { createClient } = await import("@supabase/supabase-js");
  const url = process.env.SUPABASE_URL;
  const chave = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !chave || chave.startsWith("cole-aqui")) {
    throw new Error("Preencha SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY no arquivo .env (veja .env.example).");
  }
  const sb = createClient(url, chave, { auth: { persistSession: false } });
  return {
    async midia(chave, tipo, bytes) {
      const { error } = await sb.storage.from("midia").upload(chave, bytes, { contentType: tipo, upsert: true, cacheControl: "31536000" });
      if (error) throw new Error(error.message);
      return sb.storage.from("midia").getPublicUrl(chave).data.publicUrl;
    },
    async decks(nomes) {
      const { data, error } = await sb.from("decks")
        .upsert(nomes.map((nome) => ({ nome, ...(opcoes.oculto ? { publicado: false } : {}) })), { onConflict: "nome" }).select("id, nome");
      if (error) throw new Error(error.message);
      return data;
    },
    async cards(linhas) {
      const { error } = await sb.from("cards").upsert(linhas, { onConflict: "anki_card_id" });
      if (error) throw new Error(error.message);
    },
  };
}

function destinoFuncao() {
  const url = process.env.IMPORTAR_URL;
  const pedirUrl = process.env.ACTIONS_ID_TOKEN_REQUEST_URL, pedirToken = process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!url || !pedirUrl || !pedirToken) throw new Error("--via-funcao só funciona dentro do GitHub Actions (com IMPORTAR_URL e permissão id-token).");
  let token = null, validoAte = 0;
  async function obterToken() {
    if (token && Date.now() < validoAte) return token;
    const r = await fetch(`${pedirUrl}&audience=pulse-medcards-importar`, { headers: { Authorization: `Bearer ${pedirToken}` } });
    if (!r.ok) throw new Error(`Não consegui o token do GitHub (${r.status}).`);
    token = (await r.json()).value; validoAte = Date.now() + 4 * 60 * 1000;
    return token;
  }
  async function chamar(corpo, tentativas = 3) {
    for (let t = 1; ; t++) {
      const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${await obterToken()}` }, body: JSON.stringify(corpo) });
      const j = await r.json().catch(() => ({}));
      if (r.ok) return j;
      if (t >= tentativas || r.status < 500) throw new Error(`Função importar respondeu ${r.status}: ${j.erro ?? "erro"}`);
      await new Promise((ok) => setTimeout(ok, 1500 * t));
    }
  }
  return {
    async midia(chave, tipo, bytes) { return (await chamar({ acao: "midia", chave, tipo, base64: Buffer.from(bytes).toString("base64") })).url; },
    async decks(nomes) { return (await chamar({ acao: "decks", nomes, oculto: opcoes.oculto })).decks; },
    async cards(linhas) { await chamar({ acao: "cards", linhas }); },
  };
}

async function enviar(todos, midias) {
  const destino = opcoes.viaFuncao ? destinoFuncao() : await destinoDireto();

  // 1) Imagens
  const nomes = new Set(todos.flatMap((c) => [...midiasReferenciadas(c.frente), ...midiasReferenciadas(c.verso)]));
  const mapa = {};
  let enviadas = 0, faltando = 0;
  for (const nome of nomes) {
    const original = midias[nome] ? nome : (() => { try { return decodeURIComponent(nome); } catch { return nome; } })();
    const ler = midias[original];
    if (!ler) { faltando++; continue; }
    const chaveArq = chaveMidia(original);
    const ext = chaveArq.split(".").pop();
    try { mapa[nome] = await destino.midia(chaveArq, MIME[ext] ?? "application/octet-stream", ler()); }
    catch (e) { throw new Error(`Erro ao enviar imagem ${original}: ${e.message}`); }
    if (++enviadas % 50 === 0) console.log(`   ${enviadas}/${nomes.size} imagens`);
  }
  console.log(`   Imagens enviadas: ${enviadas}${faltando ? ` (${faltando} não encontradas no pacote)` : ""}`);

  // 2) Decks
  const nomesDecks = [...new Set(todos.map((c) => nomeFinal(c.deck)))];
  const decks = await destino.decks(nomesDecks);
  const idDeck = Object.fromEntries(decks.map((d) => [d.nome, d.id]));

  // 3) Cards em lotes
  const linhas = todos.map((c, i) => ({
    anki_card_id: c.anki_card_id,
    deck_id: idDeck[nomeFinal(c.deck)],
    frente: trocarMidias(c.frente, mapa),
    verso: trocarMidias(c.verso, mapa),
    tags: c.tags,
    ordem: i,
    atualizado_em: new Date().toISOString(),
  }));
  const lote = opcoes.viaFuncao ? 200 : 500;
  for (let i = 0; i < linhas.length; i += lote) {
    try { await destino.cards(linhas.slice(i, i + lote)); }
    catch (e) { throw new Error(`Erro ao gravar cards: ${e.message}`); }
  }
  console.log(`   Cards gravados: ${linhas.length} em ${nomesDecks.length} decks: ${nomesDecks.join(", ")}`);
}

// ---------- execução ----------
try {
  let todos = [];
  const midias = {};
  for (const arq of arquivos) {
    console.log(`📦 Lendo ${path.basename(arq)}...`);
    const r = await lerApkg(arq);
    const ativos = r.cards.filter((c) => !c.suspenso);
    console.log(`   ${ativos.length} cards${r.ignorados ? `, ${r.ignorados} ignorados (vazios ou sem modelo)` : ""}` +
      `${r.cards.length - ativos.length ? `, ${r.cards.length - ativos.length} suspensos não importados` : ""}`);
    todos = todos.concat(ativos);
    Object.assign(midias, r.midias);
  }

  if (opcoes.previa) {
    const arq = gerarPrevia(todos, midias);
    console.log(`\n✅ Prévia gerada: ${arq}\n   Abra no navegador para conferir antes de enviar.`);
  } else {
    console.log("\n☁️  Enviando para a plataforma...");
    await enviar(todos, midias);
    console.log("\n✅ Importação concluída.");
  }
} catch (e) {
  console.error(`\n❌ ${e.message}`);
  process.exit(1);
}
