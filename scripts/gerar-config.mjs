// Gera app/config.js a partir das variáveis de ambiente da Vercel.
// Roda automaticamente em cada deploy (vercel.json -> buildCommand).
// Sem as variáveis, gera um config vazio e o app abre em modo demonstração.
import { writeFileSync } from "node:fs";

const env = (nome) => (process.env[nome] ?? "").trim();

const config = {
  NOME: env("MEDFLASH_NOME") || env("NOME_APP"),
  SUPABASE_URL: env("SUPABASE_URL").replace(/\/$/, ""),
  SUPABASE_ANON_KEY: env("SUPABASE_ANON_KEY"),
  CHECKOUT_URL: env("CHECKOUT_URL"),
  CHECKOUT_MENSAL: env("CHECKOUT_MENSAL"),
  CHECKOUT_ANUAL: env("CHECKOUT_ANUAL"),
  SUPORTE: env("SUPORTE"),
};

// Proteção: nunca publicar a service_role key no site.
if (/service_role/.test(Buffer.from(config.SUPABASE_ANON_KEY.split(".")[1] ?? "", "base64").toString())) {
  console.error("ERRO: SUPABASE_ANON_KEY contém a service_role key. Use a chave 'anon public'.");
  process.exit(1);
}
if (config.SUPABASE_ANON_KEY.startsWith("sb_secret_")) {
  console.error("ERRO: SUPABASE_ANON_KEY contém uma chave secreta. Use a chave publicável (anon / sb_publishable_).");
  process.exit(1);
}

writeFileSync(
  new URL("../app/config.js", import.meta.url),
  `// Gerado automaticamente por scripts/gerar-config.mjs. Não edite.\nwindow.MEDFLASH_CONFIG = ${JSON.stringify(config, null, 2)};\n`,
);
console.log(config.SUPABASE_URL ? `config.js gerado para ${config.SUPABASE_URL}` : "config.js gerado em MODO DEMONSTRAÇÃO (sem SUPABASE_URL)");
