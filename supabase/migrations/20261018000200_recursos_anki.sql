-- Recursos no estilo Anki: favoritos, busca de cards, card do dia,
-- contagens Novos / Aprendendo / Revisar por deck e previsão de revisões.

-- Favoritos (o coração no card). "ativo" permite marcar e desmarcar sem apagar linhas.
create table if not exists public.favoritos (
  user_id   uuid not null references auth.users(id) on delete cascade,
  card_id   uuid not null references public.cards(id) on delete cascade,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now(),
  primary key (user_id, card_id)
);
alter table public.favoritos enable row level security;

drop policy if exists "favoritos: dono le" on public.favoritos;
drop policy if exists "favoritos: dono grava" on public.favoritos;
drop policy if exists "favoritos: dono altera" on public.favoritos;
create policy "favoritos: dono le" on public.favoritos
  for select to authenticated using (user_id = auth.uid());
create policy "favoritos: dono grava" on public.favoritos
  for insert to authenticated with check (user_id = auth.uid() and public.tem_acesso());
create policy "favoritos: dono altera" on public.favoritos
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Marca/desmarca um favorito e devolve o novo estado
create or replace function public.alternar_favorito(p_card uuid)
returns boolean
language sql volatile security invoker set search_path = public
as $$
  insert into public.favoritos(user_id, card_id, ativo)
  values (auth.uid(), p_card, true)
  on conflict (user_id, card_id) do update set ativo = not public.favoritos.ativo
  returning ativo;
$$;

-- Decks com as três contagens do Anki para o aluno
create or replace function public.painel_decks()
returns table(id uuid, nome text, descricao text, total bigint, estudados bigint,
              aprendendo bigint, revisar bigint, maduros bigint, novos_hoje bigint)
language sql stable security invoker set search_path = public
as $$
  select d.id, d.nome, d.descricao,
    (select count(*) from public.cards c where c.deck_id = d.id),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
       and p.estado = 'aprendendo' and p.vencimento <= now()),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
       and p.estado = 'revisao' and p.vencimento <= now()),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
       and p.intervalo >= 21),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
       and p.criado_em >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')
  from public.decks d
  where d.publicado
  order by d.ordem, d.nome;
$$;

-- Busca no texto dos cards (como o "Navegador" do Anki). Só devolve cards que o aluno pode ver.
create or replace function public.buscar_cards(p_termo text default '', p_somente_favoritos boolean default false, p_limite int default 60)
returns table(card_id uuid, deck_id uuid, deck text, frente text, verso text, favorito boolean,
              estado text, vencimento timestamptz, intervalo int)
language sql stable security invoker set search_path = public
as $$
  select c.id, c.deck_id, d.nome, c.frente, c.verso,
         coalesce(f.ativo, false), p.estado, p.vencimento, p.intervalo
  from public.cards c
  join public.decks d on d.id = c.deck_id and d.publicado
  left join public.favoritos f on f.card_id = c.id and f.user_id = auth.uid()
  left join public.progresso p on p.card_id = c.id and p.user_id = auth.uid()
  where (not p_somente_favoritos or coalesce(f.ativo, false))
    and (coalesce(trim(p_termo), '') = ''
         or c.frente ilike '%' || p_termo || '%'
         or c.verso  ilike '%' || p_termo || '%'
         or d.nome   ilike '%' || p_termo || '%')
  order by d.nome, c.ordem
  limit least(greatest(p_limite, 1), 200);
$$;

-- Um card diferente por dia para a tela inicial
create or replace function public.card_do_dia(p_salto int default 0)
returns table(card_id uuid, deck text, frente text, verso text)
language sql stable security invoker set search_path = public
as $$
  select c.id, d.nome, c.frente, c.verso
  from public.cards c join public.decks d on d.id = c.deck_id and d.publicado
  order by md5(c.id::text || (now() at time zone 'America/Sao_Paulo')::date::text || p_salto::text)
  limit 1;
$$;

-- Fila com os cards favoritos (estudo extra, como um deck filtrado do Anki)
create or replace function public.fila_favoritos(p_limite int default 200)
returns table(card_id uuid, deck_id uuid, frente text, verso text, novo boolean,
              ease real, intervalo int, repeticoes int, lapsos int, estado text)
language sql stable security invoker set search_path = public
as $$
  select c.id, c.deck_id, c.frente, c.verso, p.card_id is null,
         coalesce(p.ease, 2.5::real), coalesce(p.intervalo, 0), coalesce(p.repeticoes, 0),
         coalesce(p.lapsos, 0), coalesce(p.estado, 'aprendendo')
  from public.favoritos f
  join public.cards c on c.id = f.card_id
  left join public.progresso p on p.card_id = c.id and p.user_id = auth.uid()
  where f.user_id = auth.uid() and f.ativo
  order by f.criado_em desc
  limit p_limite;
$$;

-- Quantos cards vencem em cada um dos próximos dias (atrasados contam para hoje)
create or replace function public.previsao_revisoes(p_dias int default 30)
returns table(dia date, quantidade bigint)
language sql stable security invoker set search_path = public
as $$
  select greatest((p.vencimento at time zone 'America/Sao_Paulo')::date,
                  (now() at time zone 'America/Sao_Paulo')::date) as dia,
         count(*)
  from public.progresso p
  where p.user_id = auth.uid()
    and p.vencimento < (now() at time zone 'America/Sao_Paulo')::date + p_dias
  group by 1 order by 1;
$$;

-- Situação de todos os cards do aluno: novos, aprendendo, jovens (< 21 dias) e maduros
create or replace function public.contagem_estados()
returns table(novos bigint, aprendendo bigint, jovens bigint, maduros bigint)
language sql stable security invoker set search_path = public
as $$
  select
    (select count(*) from public.cards c join public.decks d on d.id = c.deck_id and d.publicado
      where not exists (select 1 from public.progresso p where p.card_id = c.id and p.user_id = auth.uid())),
    count(*) filter (where p.estado = 'aprendendo'),
    count(*) filter (where p.estado = 'revisao' and p.intervalo < 21),
    count(*) filter (where p.estado = 'revisao' and p.intervalo >= 21)
  from public.progresso p where p.user_id = auth.uid();
$$;

revoke execute on function public.alternar_favorito(uuid), public.painel_decks(),
  public.buscar_cards(text, boolean, int), public.card_do_dia(int), public.fila_favoritos(int),
  public.previsao_revisoes(int), public.contagem_estados() from public, anon;
grant execute on function public.alternar_favorito(uuid), public.painel_decks(),
  public.buscar_cards(text, boolean, int), public.card_do_dia(int), public.fila_favoritos(int),
  public.previsao_revisoes(int), public.contagem_estados() to authenticated;
