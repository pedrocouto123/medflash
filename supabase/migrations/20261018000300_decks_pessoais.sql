-- Decks criados pelo aluno ("Meus decks").
-- Ficam na mesma tabela de decks, com dono. Só o dono vê. Cards excluídos ficam marcados (excluido).

alter table public.decks add column if not exists dono uuid references auth.users(id) on delete cascade;
alter table public.decks add column if not exists titulo text;
alter table public.cards add column if not exists excluido boolean not null default false;
create index if not exists decks_dono_idx on public.decks(dono);

alter policy "decks: assinantes leem" on public.decks
  using (publicado and (dono is null or dono = auth.uid()));
alter policy "cards: assinantes leem" on public.cards
  using (not excluido and public.tem_acesso()
         and exists (select 1 from public.decks d where d.id = deck_id and d.publicado and (d.dono is null or d.dono = auth.uid())));

-- Nome exibido: decks do aluno aparecem na área "Meus decks"
create or replace function public.nome_exibido(d public.decks)
returns text language sql immutable set search_path = public
as $$ select case when d.dono is not null then 'Meus decks::' || coalesce(nullif(trim(d.titulo), ''), 'Sem nome') else d.nome end $$;

create or replace function public.painel_decks()
returns table(id uuid, nome text, descricao text, total bigint, estudados bigint,
              aprendendo bigint, revisar bigint, maduros bigint, novos_hoje bigint)
language sql stable security invoker set search_path = public
as $$
  select d.id, public.nome_exibido(d), d.descricao,
    (select count(*) from public.cards c where c.deck_id = d.id),
    (select count(*) from public.progresso p join public.cards c on c.id = p.card_id where p.deck_id = d.id and p.user_id = auth.uid()),
    (select count(*) from public.progresso p join public.cards c on c.id = p.card_id where p.deck_id = d.id and p.user_id = auth.uid()
       and p.estado = 'aprendendo' and p.vencimento <= now()),
    (select count(*) from public.progresso p join public.cards c on c.id = p.card_id where p.deck_id = d.id and p.user_id = auth.uid()
       and p.estado = 'revisao' and p.vencimento <= now()),
    (select count(*) from public.progresso p join public.cards c on c.id = p.card_id where p.deck_id = d.id and p.user_id = auth.uid()
       and p.intervalo >= 21),
    (select count(*) from public.progresso p where p.deck_id = d.id and p.user_id = auth.uid()
       and p.criado_em >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')
  from public.decks d
  where d.publicado
  order by (d.dono is null), d.ordem, public.nome_exibido(d);
$$;

create or replace function public.buscar_cards(p_termo text default '', p_somente_favoritos boolean default false, p_limite int default 60)
returns table(card_id uuid, deck_id uuid, deck text, frente text, verso text, favorito boolean,
              estado text, vencimento timestamptz, intervalo int)
language sql stable security invoker set search_path = public
as $$
  select c.id, c.deck_id, public.nome_exibido(d), c.frente, c.verso,
         coalesce(f.ativo, false), p.estado, p.vencimento, p.intervalo
  from public.cards c
  join public.decks d on d.id = c.deck_id and d.publicado
  left join public.favoritos f on f.card_id = c.id and f.user_id = auth.uid()
  left join public.progresso p on p.card_id = c.id and p.user_id = auth.uid()
  where (not p_somente_favoritos or coalesce(f.ativo, false))
    and (coalesce(trim(p_termo), '') = ''
         or c.frente ilike '%' || p_termo || '%'
         or c.verso  ilike '%' || p_termo || '%'
         or public.nome_exibido(d) ilike '%' || p_termo || '%')
  order by d.nome, c.ordem
  limit least(greatest(p_limite, 1), 200);
$$;

create or replace function public.card_do_dia(p_salto int default 0)
returns table(card_id uuid, deck text, frente text, verso text)
language sql stable security invoker set search_path = public
as $$
  select c.id, d.nome, c.frente, c.verso
  from public.cards c join public.decks d on d.id = c.deck_id and d.publicado and d.dono is null
  order by md5(c.id::text || (now() at time zone 'America/Sao_Paulo')::date::text || p_salto::text)
  limit 1;
$$;

create or replace function public.minhas_estatisticas(p_dias int default 30)
returns table(deck_id uuid, deck text, respostas bigint, acertos bigint)
language sql stable security invoker set search_path = public
as $$
  select r.deck_id, public.nome_exibido(d), count(*), count(*) filter (where r.nota >= 3)
  from public.revisoes r join public.decks d on d.id = r.deck_id
  where r.user_id = auth.uid() and r.revisado_em > now() - make_interval(days => p_dias)
  group by r.deck_id, d.id
  order by count(*) desc;
$$;

-- ---------- ações do aluno (conferem o dono antes de gravar) ----------
create or replace function public.criar_deck(p_titulo text)
returns uuid language plpgsql volatile security definer set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'sem acesso'; end if;
  if coalesce(trim(p_titulo), '') = '' then raise exception 'Dê um nome ao deck.'; end if;
  if (select count(*) from public.decks where dono = auth.uid() and publicado) >= 100 then
    raise exception 'Limite de 100 decks pessoais.'; end if;
  insert into public.decks(nome, titulo, dono, ordem)
  values ('pessoal:' || gen_random_uuid(), left(trim(p_titulo), 80), auth.uid(), 1000)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.renomear_deck(p_deck uuid, p_titulo text)
returns void language plpgsql volatile security definer set search_path = public
as $$
begin
  if coalesce(trim(p_titulo), '') = '' then raise exception 'Dê um nome ao deck.'; end if;
  update public.decks set titulo = left(trim(p_titulo), 80) where id = p_deck and dono = auth.uid();
  if not found then raise exception 'Deck não encontrado.'; end if;
end $$;

create or replace function public.arquivar_deck(p_deck uuid)
returns void language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.decks set publicado = false where id = p_deck and dono = auth.uid();
  if not found then raise exception 'Deck não encontrado.'; end if;
end $$;

create or replace function public.salvar_card(p_deck uuid, p_card uuid, p_frente text, p_verso text)
returns uuid language plpgsql volatile security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.tem_acesso() then raise exception 'sem acesso'; end if;
  if not exists (select 1 from public.decks where id = p_deck and dono = auth.uid() and publicado) then
    raise exception 'Deck não encontrado.'; end if;
  if coalesce(trim(p_frente), '') = '' then raise exception 'Escreva a frente do card.'; end if;
  if length(p_frente) > 20000 or length(coalesce(p_verso, '')) > 20000 then raise exception 'Texto longo demais.'; end if;
  if p_card is null then
    if (select count(*) from public.cards where deck_id = p_deck and not excluido) >= 5000 then
      raise exception 'Limite de 5.000 cards por deck.'; end if;
    insert into public.cards(deck_id, frente, verso, ordem)
    values (p_deck, p_frente, coalesce(p_verso, ''), (extract(epoch from now()) * 1000)::bigint)
    returning id into v_id;
  else
    update public.cards set frente = p_frente, verso = coalesce(p_verso, ''), atualizado_em = now()
    where id = p_card and deck_id = p_deck returning id into v_id;
    if v_id is null then raise exception 'Card não encontrado.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.excluir_card(p_card uuid)
returns void language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.cards c set excluido = true
  where c.id = p_card and exists (select 1 from public.decks d where d.id = c.deck_id and d.dono = auth.uid());
  if not found then raise exception 'Card não encontrado.'; end if;
end $$;

-- Copia um card da plataforma (ou de outro deck seu) para um deck seu
create or replace function public.copiar_card(p_card uuid, p_deck uuid)
returns uuid language plpgsql volatile security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.tem_acesso() then raise exception 'sem acesso'; end if;
  if not exists (select 1 from public.decks where id = p_deck and dono = auth.uid() and publicado) then
    raise exception 'Deck não encontrado.'; end if;
  insert into public.cards(deck_id, frente, verso, tags, ordem)
  select p_deck, c.frente, c.verso, c.tags, (extract(epoch from now()) * 1000)::bigint
  from public.cards c join public.decks d on d.id = c.deck_id
  where c.id = p_card and not c.excluido and d.publicado and (d.dono is null or d.dono = auth.uid())
  returning id into v_id;
  if v_id is null then raise exception 'Card não encontrado.'; end if;
  return v_id;
end $$;

revoke execute on function public.criar_deck(text), public.renomear_deck(uuid, text), public.arquivar_deck(uuid),
  public.salvar_card(uuid, uuid, text, text), public.excluir_card(uuid), public.copiar_card(uuid, uuid),
  public.nome_exibido(public.decks) from public, anon;
grant execute on function public.criar_deck(text), public.renomear_deck(uuid, text), public.arquivar_deck(uuid),
  public.salvar_card(uuid, uuid, text, text), public.excluir_card(uuid), public.copiar_card(uuid, uuid),
  public.nome_exibido(public.decks) to authenticated;
