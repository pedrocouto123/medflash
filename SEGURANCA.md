# Segurança — Pulse Medcards

Revisão de 19/10/2026. O que está em vigor e o que ainda depende de configuração manual.

## Em vigor
- **Banco com privilégio mínimo**: alunos logados só leem/gravam o que o app usa; `config`, `webhook_log`, `kiwify_assinaturas` e `uso_leituras` ficam só no servidor. Visitantes sem login não acessam nenhuma tabela nem função.
- **Conteúdo protegido contra raspagem**: o texto dos cards (`frente`/`verso`) não sai por consulta direta, só por funções que conferem acesso, limitam o tamanho do pedido e contam leituras por dia (teste grátis: 400/dia; assinante: 5.000/dia — ajustável em `config`).
- **Busca sem resposta**: a busca devolve só um trecho da pergunta (máx. 60 resultados); a resposta é aberta card a card (`ver_card`, conta na cota).
- **Anti-XSS**: o app sanitiza todo HTML de card antes de exibir (lista de tags/atributos permitidos; sem `on*`, `javascript:`, iframes, scripts, SVG). O importador também limpa na entrada.
- **Cabeçalhos HTTP**: CSP restritiva, HSTS, X-Frame-Options DENY, nosniff, Referrer-Policy, Permissions-Policy, COOP.
- **Webhook Kiwify**: assinatura HMAC conferida em tempo constante; o log guarda só e-mail, nome, ids e plano (sem CPF, telefone, endereço). Logs antigos foram limpos.
- **Importação**: só aceita o token OIDC do workflow `importar-decks.yml` na branch `main` deste repositório; só aceita imagens/áudio comuns até 15 MB.
- **Storage `midia`**: só tipos de imagem/áudio, até 15 MB (sem HTML/SVG).
- **Extensão `http`**: inacessível para usuários.
- Nenhuma chave secreta no site nem no GitHub (o build recusa a service_role).

## Pendências manuais (painéis)
1. **SMTP próprio + confirmação de e-mail** (Supabase → Auth): hoje alguém pode criar conta com o e-mail de outra pessoa antes dela.
2. **Proteção contra senhas vazadas** (Supabase → Auth → Passwords) e senha mínima de 8 caracteres.
3. **CAPTCHA no cadastro** (Supabase → Auth → Bot protection, Turnstile).
4. **Redirect URLs**: deixar só `https://medflash-five.vercel.app/**` (e o domínio próprio quando houver).
5. **Trocar os tokens dos webhooks da Kiwify** (foram compartilhados em chat) e atualizar `config.kiwify_tokens`.
6. **2FA** em GitHub, Vercel, Supabase, Kiwify, Google e Registro.br, para todos os sócios.
7. **Backups**: o plano gratuito do Supabase não tem backup diário confiável — considerar o Pro antes de ter muitos assinantes.
8. **LGPD**: publicar Política de Privacidade e Termos; definir retenção do `webhook_log` (ex.: 12 meses).
