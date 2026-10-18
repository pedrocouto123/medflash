-- =====================================================================
-- MedFlash — banco de dados (Supabase / PostgreSQL)
-- Aplicado automaticamente pelo GitHub Actions (supabase db push).
-- Também pode ser colado em Supabase > SQL Editor e executado mais de
-- uma vez sem perder dados.
-- Mudanças futuras: crie um NOVO arquivo em supabase/migrations/ em vez
-- de editar este (migrations já aplicadas não rodam de novo).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------

-- Decks (baralhos). O nome segue a hierarquia do Anki: "Clínica Médica::Cardiologia::IC"
create table if not exists public.decks (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  descricao   text,
  publicado   boolean not null default true,
  ordem       int not null default 0,
  criado_em   timestamptz not null default now()
);

-- Cards já renderizados (frente/verso em HTML)
create table if not exists public.cards (
  id             uuid primary key default gen_random_uuid(),
  deck_id        uuid not null references public.decks(id) on delete cascade,
  anki_card_id   bigint unique,            -- permite reimportar sem duplicar
  frente         text not null,
  verso          text not null,
  tags           text[] not null default '{}',
  ordem          bigint not null default 0,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index if not exists cards_deck_idx on public.cards(deck_id, ordem);

-- Progresso de cada aluno em cada card (revisão espaçada)
create table if not exists public.progresso (
  user_id        uuid not null references auth.users(id) on delete cascade,
  card_id        uuid not null references public.cards(id) on delete cascade,
  deck_id        uuid not null references public.decks(id) on delete cascade,
  ease           real not null default 2.5,
  intervalo      int  not null default 0,      -- em dias
  repeticoes     int  not null default 0,
  lapsos         int  not null default 0,
  estado         text not null default 'aprendendo', -- aprendendo | revisao
  vencimento     timestamptz not null default now(),
  ultima_revisao timestamptz,
  criado_em      timestamptz not null default now(),
  primary key (user_id, card_id)
);
create index if not exists progresso_venc_idx on public.progresso(user_id, deck_id, vencimento);

-- Histórico de respostas (estatísticas)
create table if not exists public.revisoes (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  card_id     uuid not null references public.cards(id) on delete cascade,
  deck_id     uuid not null references public.decks(id) on delete cascade,
  nota        smallint not null check (nota between 1 and 4), -- 1 errei, 2 difícil, 3 bom, 4 fácil
  revisado_em timestamptz not null default now()
);
create index if not exists revisoes_user_idx on public.revisoes(user_id, revisado_em);

-- Assinaturas (preenchida pelo webhook da Kiwify)
create table if not exists public.assinaturas (
  email               text primary key,
  user_id             uuid references auth.users(id) on delete set null,
  nome                text,
  status              text not null default 'ativa', -- ativa | atrasada | cancelada | reembolsada
  kiwify_assinatura   text,
  kiwify_pedido       text,
  plano               text,
  expira_em           timestamptz,                    -- até quando o acesso vale
  atualizado_em       timestamptz not null default now(),
  criado_em           timestamptz not null default now()
);
create index if not exists assinaturas_user_idx on public.assinaturas(user_id);

-- Registro bruto dos webhooks (para auditoria e suporte)
create table if not exists public.webhook_log (
  id          bigint generated always as identity primary key,
  evento      text,
  email       text,
  payload     jsonb,
  recebido_em timestamptz not null default now()
);

-- Dispositivos conectados por aluno (limite contra compartilhamento de conta)
create table if not exists public.dispositivos (
  user_id       uuid not null references auth.users(id) on delete cascade,
  dispositivo   text not null,
  descricao     text,
  ultimo_acesso timestamptz not null default now(),
  primary key (user_id, dispositivo)
);

-- Configurações gerais
create table if not exists public.config (
  chave text primary key,
  valor text not null
);
insert into public.config(chave, valor) values
  ('max_dispositivos', '2'),
  ('dias_carencia_atraso', '3')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- 2. FUNÇÕES DE ACESSO
-- ---------------------------------------------------------------------

-- O aluno logado tem assinatura válida?
create or replace function public.tem_acesso()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.assinaturas a
    where (a.user_id = auth.uid()
           or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
      and (
        (a.status = 'ativa'     and (a.expira_em is null or a.expira_em > now()))
     or (a.status = 'atrasada'  and a.expira_em is not null and a.expira_em
           + make_interval(days => (select valor::int from public.config where chave = 'dias_carencia_atraso')) > now())
     or (a.status = 'cancelada' and a.expira_em is not null and a.expira_em > now())
      )
  );
$$;

-- Situação da assinatura (para o app mostrar mensagens)
create or replace function public.minha_assinatura()
returns table(status text, expira_em timestamptz, plano text, acesso boolean)
language sql stable security definer set search_path = public
as $$
  select a.status, a.expira_em, a.plano, public.tem_acesso()
  from public.assinaturas a
  where a.user_id = auth.uid()
     or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  order by a.atualizado_em desc
  limit 1;
$$;

-- Registra o aparelho atual e derruba o mais antigo se passar do limite
create or replace function public.registrar_dispositivo(p_dispositivo text, p_descricao text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_max int := (select valor::int from public.config where chave = 'max_dispositivos');
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  insert into public.dispositivos(user_id, dispositivo, descricao, ultimo_acesso)
  values (auth.uid(), p_dispositivo, left(p_descricao, 120), now())
  on conflict (user_id, dispositivo) do update set ultimo_acesso = now(), descricao = excluded.descricao;

  delete from public.dispositivos d
  where d.user_id = auth.uid()
    and d.dispositivo not in (
      select dispositivo from public.dispositivos
      where user_id = auth.uid()
      order by ultimo_acesso desc
      limit v_max
    );
end;
$$;

-- Este aparelho ainda está autorizado?
create or replace function public.dispositivo_valido(p_dispositivo text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  update public.dispositivos set ultimo_acesso = now()
  where user_id = auth.uid() and dispositivo = p_dispositivo;
  return found;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. FUNÇÕES DE ESTUDO
-- ---------------------------------------------------------------------

-- Lista de decks com contadores do aluno
create or replace function public.resumo_decks()
returns table(id uuid, nome text, descricao text, total bigint, estudados bigint, vencidos bigint)
language sql stable security invoker set search_path = public
as $$
  select d.id, d.nome, d.descricao,
         (select count(*) from public.cards c where c.deck_id = d.id),
         (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()),
         (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
            and p.vencimento <= now())
  from public.decks d
  where d.publicado
  order by d.ordem, d.nome;
$$;

-- Fila de estudo: cards vencidos + cards novos (respeitando o limite diário)
-- p_decks: lista de decks (permite estudar um deck e seus subdecks juntos)
create or replace function public.fila_estudo(p_decks uuid[], p_novos_por_dia int default 20, p_limite int default 200)
returns table(card_id uuid, deck_id uuid, frente text, verso text, novo boolean,
              ease real, intervalo int, repeticoes int, lapsos int, estado text)
language sql stable security invoker set search_path = public
as $$
  with vencidos as (
    select c.id, c.deck_id, c.frente, c.verso, false as novo,
           p.ease, p.intervalo, p.repeticoes, p.lapsos, p.estado, p.vencimento as ord
    from public.progresso p
    join public.cards c on c.id = p.card_id
    where p.user_id = auth.uid() and p.deck_id = any(p_decks) and p.vencimento <= now()
    order by p.vencimento
    limit p_limite
  ),
  novos_hoje as (
    select count(*) as n from public.progresso p
    where p.user_id = auth.uid() and p.deck_id = any(p_decks)
      and p.criado_em >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'
  ),
  novos as (
    select c.id, c.deck_id, c.frente, c.verso, true as novo,
           2.5::real as ease, 0 as intervalo, 0 as repeticoes, 0 as lapsos,
           'aprendendo'::text as estado, null::timestamptz as ord
    from public.cards c
    where c.deck_id = any(p_decks)
      and not exists (select 1 from public.progresso p where p.user_id = auth.uid() and p.card_id = c.id)
    order by c.ordem
    limit greatest(0, p_novos_por_dia - (select n from novos_hoje))
  )
  select id, deck_id, frente, verso, novo, ease, intervalo, repeticoes, lapsos, estado from vencidos
  union all
  select id, deck_id, frente, verso, novo, ease, intervalo, repeticoes, lapsos, estado from novos;
$$;

-- Grava a resposta do aluno (progresso + histórico) numa única chamada
create or replace function public.responder_card(
  p_card uuid, p_nota int, p_ease real, p_intervalo int, p_repeticoes int,
  p_lapsos int, p_estado text, p_vencimento timestamptz)
returns void
language plpgsql security invoker set search_path = public
as $$
declare v_deck uuid;
begin
  select deck_id into v_deck from public.cards where id = p_card;
  if v_deck is null then raise exception 'card não encontrado ou sem acesso'; end if;

  insert into public.progresso(user_id, card_id, deck_id, ease, intervalo, repeticoes, lapsos, estado, vencimento, ultima_revisao)
  values (auth.uid(), p_card, v_deck, p_ease, p_intervalo, p_repeticoes, p_lapsos, p_estado, p_vencimento, now())
  on conflict (user_id, card_id) do update set
    ease = excluded.ease, intervalo = excluded.intervalo, repeticoes = excluded.repeticoes,
    lapsos = excluded.lapsos, estado = excluded.estado, vencimento = excluded.vencimento,
    ultima_revisao = now();

  insert into public.revisoes(user_id, card_id, deck_id, nota) values (auth.uid(), p_card, v_deck, p_nota);
end;
$$;

-- Estatísticas dos últimos N dias
create or replace function public.minhas_estatisticas(p_dias int default 30)
returns table(deck_id uuid, deck text, respostas bigint, acertos bigint)
language sql stable security invoker set search_path = public
as $$
  select r.deck_id, d.nome, count(*), count(*) filter (where r.nota >= 3)
  from public.revisoes r join public.decks d on d.id = r.deck_id
  where r.user_id = auth.uid() and r.revisado_em > now() - make_interval(days => p_dias)
  group by r.deck_id, d.nome
  order by count(*) desc;
$$;

create or replace function public.revisoes_por_dia(p_dias int default 30)
returns table(dia date, respostas bigint, acertos bigint)
language sql stable security invoker set search_path = public
as $$
  select (r.revisado_em at time zone 'America/Sao_Paulo')::date, count(*), count(*) filter (where r.nota >= 3)
  from public.revisoes r
  where r.user_id = auth.uid() and r.revisado_em > now() - make_interval(days => p_dias)
  group by 1 order by 1;
$$;

-- ---------------------------------------------------------------------
-- 4. SEGURANÇA (Row Level Security)
-- Sem assinatura ativa o aluno não enxerga nenhum card.
-- ---------------------------------------------------------------------
alter table public.decks        enable row level security;
alter table public.cards        enable row level security;
alter table public.progresso    enable row level security;
alter table public.revisoes     enable row level security;
alter table public.assinaturas  enable row level security;
alter table public.webhook_log  enable row level security;
alter table public.dispositivos enable row level security;
alter table public.config       enable row level security;

drop policy if exists "decks: assinantes leem"   on public.decks;
drop policy if exists "cards: assinantes leem"   on public.cards;
drop policy if exists "progresso: dono"          on public.progresso;
drop policy if exists "revisoes: dono le"        on public.revisoes;
drop policy if exists "revisoes: dono grava"     on public.revisoes;
drop policy if exists "assinaturas: dono le"     on public.assinaturas;
drop policy if exists "dispositivos: dono le"    on public.dispositivos;
drop policy if exists "dispositivos: dono apaga" on public.dispositivos;

-- Lista de decks é visível a qualquer usuário logado (para mostrar o catálogo);
-- o conteúdo dos cards só para assinantes.
create policy "decks: assinantes leem" on public.decks
  for select to authenticated using (publicado);

create policy "cards: assinantes leem" on public.cards
  for select to authenticated
  using (public.tem_acesso() and exists (select 1 from public.decks d where d.id = deck_id and d.publicado));

create policy "progresso: dono" on public.progresso
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.tem_acesso());

create policy "revisoes: dono le" on public.revisoes
  for select to authenticated using (user_id = auth.uid());
create policy "revisoes: dono grava" on public.revisoes
  for insert to authenticated with check (user_id = auth.uid() and public.tem_acesso());

create policy "assinaturas: dono le" on public.assinaturas
  for select to authenticated
  using (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

create policy "dispositivos: dono le" on public.dispositivos
  for select to authenticated using (user_id = auth.uid());
create policy "dispositivos: dono apaga" on public.dispositivos
  for delete to authenticated using (user_id = auth.uid());

-- webhook_log e config: sem políticas = só o servidor (service role) acessa.

grant execute on function public.tem_acesso, public.minha_assinatura, public.registrar_dispositivo,
  public.dispositivo_valido, public.resumo_decks, public.fila_estudo, public.responder_card,
  public.minhas_estatisticas, public.revisoes_por_dia to authenticated;
revoke execute on function public.registrar_dispositivo, public.dispositivo_valido from anon;

-- ---------------------------------------------------------------------
-- 5. ARMAZENAMENTO DE IMAGENS DOS CARDS
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('midia', 'midia', true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 6. VINCULA A ASSINATURA AO USUÁRIO QUANDO A CONTA É CRIADA
-- ---------------------------------------------------------------------
create or replace function public.vincular_assinatura()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.assinaturas set user_id = new.id
  where lower(email) = lower(new.email) and user_id is null;
  return new;
end;
$$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.vincular_assinatura();

-- =====================================================================
-- COMANDOS ÚTEIS (rodar manualmente quando precisar)
-- ---------------------------------------------------------------------
-- Liberar acesso manual (cortesia, parceiro, teste) por 1 ano:
--   insert into public.assinaturas(email, status, plano, expira_em)
--   values ('aluno@email.com', 'ativa', 'cortesia', now() + interval '1 year')
--   on conflict (email) do update set status='ativa', expira_em = excluded.expira_em;
--
-- Mudar o limite de aparelhos por aluno:
--   update public.config set valor = '3' where chave = 'max_dispositivos';
--
-- Ver as últimas notificações recebidas da Kiwify:
--   select * from public.webhook_log order by id desc limit 20;
-- =====================================================================
