# Pulse Medcards — Guia de implantação

Plataforma de flashcards para residência médica com login, assinatura pela Kiwify e revisão espaçada no estilo do Anki.

Código no GitHub, site na Vercel e banco/webhook no Supabase. Depois de configurado, **todo `git push` na `main` publica sozinho**: a Vercel atualiza o site e o GitHub Actions atualiza o banco e o webhook.

Siga as etapas na ordem. Tempo estimado na primeira vez: 1 a 2 horas.

---

## Como as peças se encaixam

```
Aluno compra na Kiwify
        │  (aviso automático = webhook)
        ▼
Supabase ── função "kiwify-webhook" cria a conta e libera o acesso
        │      e envia o e-mail "crie sua senha"
        ▼
App Pulse Medcards (site hospedado na Vercel)
        │  aluno entra com e-mail e senha
        ▼
Banco de dados do Supabase só entrega os cards se a assinatura estiver ativa
```

| Pasta / arquivo | O que é |
|---|---|
| `app/` | O site que o aluno usa (publicado pela Vercel). |
| `vercel.json` + `scripts/gerar-config.mjs` | Configuração da Vercel; gera `app/config.js` a partir das variáveis de ambiente. |
| `supabase/migrations/` | Banco de dados, regras de acesso e armazenamento de imagens. |
| `supabase/functions/kiwify-webhook/index.ts` | Recebe os avisos da Kiwify (compra, renovação, cancelamento, reembolso). |
| `.github/workflows/supabase.yml` | Publica banco e webhook no Supabase a cada push. |
| `importador/` | Programa que lê seus `.apkg` do Anki e envia os cards para a plataforma. |

**Abrir `app/index.html` sem configurar nada** (ou publicar na Vercel sem variáveis) mostra o app em modo demonstração, com cards de exemplo.

---

## Etapa 1 — Criar o projeto no Supabase

1. Crie uma conta em <https://supabase.com> e clique em **New project**.
2. Dê um nome (ex.: `medflash`), crie uma senha forte para o banco (guarde-a) e escolha a região **South America (São Paulo)**.
3. Quando o projeto terminar de criar, abra **Project Settings → API** e anote:
   - **Project URL** (ex.: `https://abcdxyz.supabase.co`)
   - **anon public** key — vai no app, pode ser pública
   - **service_role** key — **secreta**, só para o importador. Nunca coloque no app nem envie a ninguém.
   - O **código do projeto** (Project ref): é o `abcdxyz` do endereço.
4. Crie um token de acesso pessoal em <https://supabase.com/dashboard/account/tokens> (**Generate new token**, nome `github-medflash`). Copie na hora; ele só aparece uma vez.

## Etapa 2 — Ligar o GitHub ao Supabase (banco + webhook automáticos)

No GitHub, abra o repositório → **Settings → Secrets and variables → Actions**.

Na aba **Secrets** → **New repository secret**, crie:

| Nome | Valor |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | o token da Etapa 1, item 4 |
| `SUPABASE_DB_PASSWORD` | a senha do banco que você criou com o projeto |
| `KIWIFY_TOKEN` | deixe para a Etapa 7 |

Na aba **Variables** → **New repository variable**, crie:

| Nome | Valor |
|---|---|
| `SUPABASE_PROJECT_REF` | o código do projeto (ex.: `abcdxyz`) |
| `APP_URL` | deixe para a Etapa 6 |

Depois vá em **Actions → Supabase → Run workflow**. Em cerca de 1 minuto ele:
- cria todas as tabelas, regras de acesso e o armazenamento de imagens;
- publica a função `kiwify-webhook` com a verificação de JWT desligada (a Kiwify não envia esse token; a segurança é a assinatura da Kiwify);
- mostra no final o endereço do webhook: `https://SEU-PROJETO.supabase.co/functions/v1/kiwify-webhook`.

Confira em **Supabase → Table Editor** se as tabelas `decks`, `cards`, `assinaturas` etc. apareceram.

> **Alterar o banco no futuro:** crie um arquivo novo em `supabase/migrations/` (ex.: `20261101000000_nova_coluna.sql`) e faça push. Não edite arquivos de migration que já foram aplicados.

## Etapa 3 — Configurar o login

Em **Authentication**:

1. **Sign In / Providers → Email**: deixe o login por e-mail ativo e **desative "Allow new users to sign up"**. Assim só entra quem comprou (as contas são criadas pelo webhook).
2. **URL Configuration**:
   - **Site URL**: o endereço do seu app (você o terá na Etapa 6; volte aqui depois).
   - **Redirect URLs**: adicione o mesmo endereço seguido de `/**` (ex.: `https://medflash.vercel.app/**`).

## Etapa 4 — Configurar o envio de e-mails (obrigatório)

O serviço de e-mail padrão do Supabase só envia para membros da sua equipe no projeto e tem limite de poucos e-mails por hora. Para os alunos receberem o convite e a recuperação de senha, configure um provedor próprio:

1. Crie conta em um provedor de e-mail transacional, como **Brevo** ou **Resend**. Você precisará verificar um domínio próprio (ex.: `medflash.com.br`), o que exige acesso ao DNS do domínio.
2. Copie os dados SMTP do provedor (servidor, porta, usuário, senha).
3. No Supabase: **Authentication → Emails → SMTP Settings → Enable custom SMTP** e preencha. Remetente sugerido: `acesso@seudominio.com.br`, nome `Pulse Medcards`.
4. Ainda em **Authentication → Emails → Templates**, troque os textos para português:

**Invite user** — assunto: `Seu acesso ao Pulse Medcards está pronto`
```html
<h2>Bem-vindo(a) ao Pulse Medcards!</h2>
<p>Sua assinatura foi confirmada. Clique no botão abaixo para criar sua senha e começar a estudar.</p>
<p><a href="{{ .ConfirmationURL }}">Criar minha senha</a></p>
<p>O link vale por 24 horas. Se expirar, use "Esqueci minha senha" na tela de login.</p>
```

**Reset password** — assunto: `Redefina sua senha do Pulse Medcards`
```html
<h2>Redefinição de senha</h2>
<p>Clique no botão abaixo para criar uma nova senha.</p>
<p><a href="{{ .ConfirmationURL }}">Criar nova senha</a></p>
<p>Se você não pediu isso, ignore este e-mail.</p>
```

## Etapa 5 — (feita na Etapa 2)

A função do webhook já é publicada pelo GitHub Actions. Nada a fazer aqui.

## Etapa 6 — Publicar o app na Vercel

1. Acesse <https://vercel.com/new>, entre com sua conta do GitHub e clique em **Import** no repositório `medflash` (se ele não aparecer, clique em **Adjust GitHub App Permissions** e libere o repositório).
2. Na tela de configuração, **não mude** Framework, Build Command nem Output Directory (o `vercel.json` já cuida disso). Abra **Environment Variables** e adicione:

   | Nome | Valor |
   |---|---|
   | `SUPABASE_URL` | Project URL (ex.: `https://abcdxyz.supabase.co`) |
   | `SUPABASE_ANON_KEY` | a chave **anon public** (nunca a service_role; o deploy recusa se for ela) |
   | `CHECKOUT_URL` | link do checkout da assinatura na Kiwify |
   | `SUPORTE` | seu e-mail ou WhatsApp de suporte |
   | `NOME_APP` | opcional; padrão "Pulse Medcards" |

3. Clique em **Deploy**. Em menos de um minuto você recebe um endereço como `https://medflash.vercel.app` (pode mudar em **Settings → Domains**, onde também liga um domínio próprio).
4. Use esse endereço em três lugares:
   - Supabase → **Site URL / Redirect URLs** (Etapa 3);
   - GitHub → variável `APP_URL` (Etapa 2) e rode **Actions → Supabase → Run workflow** de novo para gravar o segredo na função.

Para atualizar o app depois, basta fazer push na `main`. Se mudar uma variável de ambiente na Vercel, vá em **Deployments → ⋯ → Redeploy** para ela valer.

## Etapa 7 — Conectar a Kiwify

1. Na Kiwify, crie o produto como **assinatura** (mensal, semestral ou anual).
2. Na entrega do produto, use a opção de entrega por link ou área externa e informe o endereço do app. O acesso de verdade é liberado pelo webhook; o link só orienta o aluno.
3. Em **Apps → Webhooks → Criar webhook**:
   - **URL**: `https://SEU-PROJETO.supabase.co/functions/v1/kiwify-webhook`
   - **Produto**: o produto da assinatura
   - **Eventos**: compra aprovada, compra reembolsada, chargeback, assinatura cancelada, assinatura atrasada, assinatura renovada
4. Copie o **token** exibido pela Kiwify e salve como secret `KIWIFY_TOKEN` no GitHub (Etapa 2). Depois rode **Actions → Supabase → Run workflow** para enviá-lo à função.

O que cada evento faz:

| Evento da Kiwify | Efeito na plataforma |
|---|---|
| Compra aprovada | Cria a conta, envia o e-mail de criação de senha e libera o acesso até a próxima cobrança (+1 dia de folga) |
| Assinatura renovada | Estende o acesso até a nova data de cobrança |
| Assinatura atrasada | Mantém o acesso por 3 dias de carência (ajustável) |
| Assinatura cancelada | Mantém o acesso até o fim do período já pago |
| Reembolso ou chargeback | Bloqueia na hora e desconecta todos os aparelhos |
| Pix/boleto gerado, carrinho abandonado | Ignorados |

## Etapa 8 — Importar seus decks do Anki

1. Instale o **Node.js** versão LTS: <https://nodejs.org>.
2. No Anki, para cada deck: **Arquivo → Exportar** → formato **Pacote de baralho Anki (.apkg)** → marque **Incluir mídia** e **Suporte a versões antigas do Anki** → Exportar.
   (Sem a opção de versões antigas, o importador avisa e pede para exportar de novo.)
3. Copie os `.apkg` para a pasta `importador`.
4. Na pasta `importador`, copie `.env.example` para `.env` e preencha a URL e a **service_role** key.
5. Abra o terminal nessa pasta (no Windows: clique na barra de endereço da pasta, digite `cmd` e Enter) e rode:
   ```
   npm install
   node importar-apkg.mjs "Clinica Medica.apkg" --previa
   ```
   Abra `previa/previa.html` no navegador e confira se os cards e imagens estão corretos.
6. Se estiver tudo certo, envie de verdade:
   ```
   node importar-apkg.mjs "Clinica Medica.apkg"
   ```

Opções úteis:
- Vários arquivos de uma vez: `node importar-apkg.mjs deck1.apkg deck2.apkg`
- Agrupar numa área: `--prefixo "Pediatria"` coloca os decks dentro de "Pediatria"
- Importar sem mostrar aos alunos: `--oculto` (publique depois mudando `publicado` para `true` na tabela `decks`)

**Como os decks aparecem:** a hierarquia do Anki vira a organização do app. Um deck chamado `Clínica Médica::Cardiologia` aparece como "Cardiologia" dentro da área "Clínica Médica". Vale organizar no Anki pelas cinco grandes áreas antes de exportar.

**Corrigir um card:** edite no Anki, exporte e importe de novo. Os cards são atualizados sem duplicar e o progresso dos alunos é mantido.

## Etapa 9 — Teste completo antes de vender

1. Libere um acesso de teste para você no **SQL Editor**:
   ```sql
   insert into public.assinaturas(email, status, plano, expira_em)
   values ('seu-email@gmail.com', 'ativa', 'teste', now() + interval '30 days')
   on conflict (email) do update set status = 'ativa', expira_em = excluded.expira_em;
   ```
2. Em **Authentication → Users → Add user → Send invitation**, convide esse e-mail. Confira se o e-mail chega, se o link abre a tela "Crie sua senha" e se você consegue estudar.
3. Faça uma compra real de baixo valor (ou peça a alguém) e confira em **Table Editor → webhook_log** se o aviso chegou e em **assinaturas** se o acesso foi criado.
4. Teste no celular: abra o endereço no navegador e use "Adicionar à tela inicial" para instalar como app.

---

## Dia a dia

Comandos para o **SQL Editor**:

```sql
-- Dar acesso de cortesia por 1 ano
insert into public.assinaturas(email, status, plano, expira_em)
values ('aluno@email.com', 'ativa', 'cortesia', now() + interval '1 year')
on conflict (email) do update set status = 'ativa', expira_em = excluded.expira_em;
-- depois, em Authentication > Users > Add user > Send invitation

-- Ver quantos assinantes ativos existem
select status, count(*) from public.assinaturas group by status;

-- Mudar o limite de aparelhos por aluno (padrão: 2)
update public.config set valor = '3' where chave = 'max_dispositivos';

-- Mudar a carência para pagamento atrasado (padrão: 3 dias)
update public.config set valor = '5' where chave = 'dias_carencia_atraso';

-- Últimos avisos recebidos da Kiwify
select recebido_em, evento, email from public.webhook_log order by id desc limit 20;
```

## Proteções incluídas

- Os cards só saem do banco para quem tem assinatura válida. A regra fica no servidor, não no app.
- Cada conta pode ficar conectada em até 2 aparelhos; ao entrar no terceiro, o mais antigo é desconectado.
- O e-mail do aluno aparece em marca d'água discreta nos cards, o que desestimula prints compartilhados.
- Seleção de texto e clique direito ficam desativados nos cards.
- Scripts embutidos nos decks do Anki são removidos na importação.

Nenhuma proteção impede totalmente que alguém fotografe a tela. O objetivo é tornar o compartilhamento trabalhoso e rastreável.

## Custos

| Serviço | Para começar | Quando crescer |
|---|---|---|
| Supabase | Gratuito: 500 MB de banco, 1 GB de imagens, 50 mil usuários/mês | Plano Pro, US$ 25/mês |
| Vercel | Gratuito (Hobby) para testar | O Hobby é só para uso **não comercial**; ao começar a vender, migre para o Pro (US$ 20/mês). Confira em <https://vercel.com/pricing> |
| GitHub | Gratuito (repositório privado) | — |
| Brevo ou Resend | Gratuito para o volume inicial | Conforme volume |
| Kiwify | Taxa por venda | — |
| Domínio `.com.br` | Cerca de R$ 40/ano no Registro.br | — |

No plano gratuito, o Supabase **pausa o projeto após 1 semana sem uso**. Com alunos estudando isso não acontece, mas antes do lançamento vale migrar para o Pro, que também inclui backups diários. Confira os valores atuais em <https://supabase.com/pricing>.

## Limitações conhecidas

- Áudio dos cards (`[sound:...]`) não é reproduzido; é removido na importação.
- O estilo visual (CSS) próprio de cada tipo de nota do Anki não é copiado; os cards usam o visual da plataforma. Negrito, cores inline, listas, tabelas e imagens funcionam.
- Campos de "digite a resposta" (`{{type:...}}`) são removidos.
- O progresso dos alunos que já usam o Anki não é importado; todos começam do zero na plataforma.

## Antes de vender

- **Conteúdo**: confirme que os decks são de sua autoria ou que você tem direito de comercializá-los.
- **LGPD**: publique termos de uso e política de privacidade (a plataforma guarda e-mail, nome e histórico de estudo).
- **Enquadramento fiscal**: como servidor público federal, confirme com um contador a melhor forma de receber (pessoa física ou empresa em que você seja apenas sócio cotista).
