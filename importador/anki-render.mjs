// Renderizador de templates do Anki (subconjunto usado na prática em decks de estudo)
// Suporta: {{Campo}}, {{FrontSide}}, {{#Campo}}...{{/Campo}}, {{^Campo}}...{{/Campo}},
// filtros cloze:, text:, hint:, type: (removido), tts (removido), {{Tags}}, {{Deck}}, {{Subdeck}}, {{Card}}.

const RE_CLOZE = /\{\{c(\d+)::([\s\S]*?)(?:::([\s\S]*?))?\}\}/g;

export function stripHtml(s) {
  return String(s ?? "").replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").trim();
}

function campoVazio(v) {
  return stripHtml(v).length === 0 && !/<img/i.test(String(v ?? ""));
}

export function renderCloze(texto, n, lado) {
  return String(texto ?? "").replace(RE_CLOZE, (_, num, resp, dica) => {
    if (Number(num) !== n) return resp;
    if (lado === "q") return `<span class="cloze">[${dica ? dica : "..."}]</span>`;
    return `<span class="cloze">${resp}</span>`;
  });
}

export function numerosCloze(texto) {
  const set = new Set();
  for (const m of String(texto ?? "").matchAll(RE_CLOZE)) set.add(Number(m[1]));
  return [...set].sort((a, b) => a - b);
}

function aplicarFiltros(valor, filtros, ctx) {
  let v = valor;
  // Filtros são aplicados da direita para a esquerda ({{text:cloze:Texto}})
  for (const f of [...filtros].reverse()) {
    const nome = f.trim().toLowerCase();
    if (nome === "cloze") v = renderCloze(v, ctx.cloze, ctx.lado);
    else if (nome === "text") v = stripHtml(v);
    else if (nome === "hint") {
      v = campoVazio(v) ? "" : `<details class="hint"><summary>Dica</summary>${v}</details>`;
    } else if (nome === "type" || nome.startsWith("tts") || nome === "furigana" || nome === "kana" || nome === "kanji") {
      v = nome === "type" ? "" : stripHtml(v);
    }
  }
  return v;
}

/**
 * Renderiza um template.
 * @param {string} tpl     qfmt ou afmt
 * @param {object} campos  { NomeDoCampo: valor }
 * @param {object} ctx     { lado: 'q'|'a', cloze: número, frontSide, tags, deck, card }
 */
export function renderTemplate(tpl, campos, ctx) {
  const valorDe = (nome) => {
    if (nome === "FrontSide") return ctx.frontSide ?? "";
    if (nome === "Tags") return (ctx.tags ?? []).join(" ");
    if (nome === "Deck") return ctx.deck ?? "";
    if (nome === "Subdeck") return (ctx.deck ?? "").split("::").pop();
    if (nome === "Card") return ctx.card ?? "";
    return campos[nome] ?? "";
  };

  // Seções condicionais (resolve de dentro para fora para suportar aninhamento)
  let s = String(tpl ?? "");
  const reSecao = /\{\{([#^])\s*([^}]+?)\s*\}\}([\s\S]*?)\{\{\/\s*\2\s*\}\}/;
  let guarda = 0;
  while (reSecao.test(s) && guarda++ < 500) {
    s = s.replace(reSecao, (_, tipo, nomeCompleto, miolo) => {
      const nome = nomeCompleto.split(":").pop().trim();
      let vazio = campoVazio(valorDe(nome));
      // Em notas cloze, {{#c1}} etc. testa se o cloze existe
      const m = /^c(\d+)$/i.exec(nome);
      if (m) vazio = Number(m[1]) !== ctx.cloze;
      return (tipo === "#" ? !vazio : vazio) ? miolo : "";
    });
  }

  // Substituições simples
  s = s.replace(/\{\{([^#^/{}][^{}]*?)\}\}/g, (_, expr) => {
    const partes = expr.split(":");
    const nome = partes.pop().trim();
    return aplicarFiltros(valorDe(nome), partes, ctx);
  });

  return limparHtml(s);
}

export function limparHtml(html) {
  return String(html)
    .replace(/\[sound:[^\]]*\]/g, "")                 // áudio não é suportado
    .replace(/<script[\s\S]*?<\/script>/gi, "")       // nunca executar scripts dos decks
    .replace(/\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "") // remove onclick etc.
    .trim();
}

/** Lista os arquivos de mídia referenciados no HTML (src="..." e url(...)) */
export function midiasReferenciadas(html) {
  const nomes = new Set();
  for (const m of String(html).matchAll(/\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi)) {
    const v = m[1] ?? m[2] ?? m[3];
    if (v && !/^(https?:|data:|\/\/)/i.test(v)) nomes.add(v);
  }
  for (const m of String(html).matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) {
    if (!/^(https?:|data:|\/\/)/i.test(m[1])) nomes.add(m[1]);
  }
  return [...nomes];
}

/** Troca nomes locais de mídia pelas URLs públicas */
export function trocarMidias(html, mapa) {
  const trocar = (v) => {
    let chave = v;
    if (!(chave in mapa)) { try { chave = decodeURIComponent(v); } catch { /* mantém */ } }
    return mapa[chave] ?? v;
  };
  return String(html)
    .replace(/\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi, (_, a, b, c) => `src="${trocar(a ?? b ?? c)}"`)
    .replace(/url\(\s*["']?([^"')]+)["']?\s*\)/gi, (_, v) => `url("${trocar(v)}")`);
}
