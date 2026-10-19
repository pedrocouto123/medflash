-- =====================================================================
-- Endurecimento de segurança
-- 1) Privilégios mínimos nas tabelas (o RLS continua valendo por cima)
-- 2) Conteúdo dos cards (frente/verso) só sai por funções que conferem acesso,
--    limitam o tamanho de cada pedido e contam a leitura diária (anti-raspagem)
-- 3) Cota diária de leitura: teste grátis e assinante com limites diferentes
-- =====================================================================

-- ---------- 1) privilégios ----------
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
grant select on public.decks to authenticated;
grant select (id, deck_id, anki_card_id, tags, ordem, criado_em, atualizado_em, excluido) on public.cards to authenticated;
grant select, insert, update, delete on public.progresso to authenticated;
grant select, insert on public.revisoes to authenticated;
grant select on public.assinaturas to authenticated;
grant select, delete on public.dispositivos to authenticated;
grant select, insert, update on public.favoritos to authenticated;
-- config, webhook_log, kiwify_assinaturas, uso_leituras: só o servidor
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- ---------- 3) cota diária de leitura ----------
insert into public.config(chave, valor) values ('leituras_dia_teste', '400'), ('leituras_dia_assinante', '5000')
on conflict (chave) do nothing;

create table if not exists public.uso_leituras (
  user_id uuid not null references auth.users(id) on delete cascade,
  dia     date not null,
  qtd     int  not null default 0,
  primary key (user_id, dia)
);
alter table public.uso_leituras enable row level security;

create or replace function public.eh_assinante()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.assinaturas a
    where (a.user_id = auth.uid() or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
      and a.status in ('ativa', 'atrasada', 'cancelada') and (a.expira_em is null or a.expira_em > now()));
$$;

-- Soma n leituras do dia; passa do limite -> erro (a consulta inteira é desfeita)
create or replace function public.consumir_leituras(n int)
returns void language plpgsql volatile security definer set search_path = public
as $$
declare v_dia date := (now() at time zone 'America/Sao_Paulo')::date; v_total int; v_lim int; v_ass boolean := public.eh_assinante();
begin
  if n <= 0 or auth.uid() is null then return; end if;
  v_lim := (select valor::int from public.config where chave = case when v_ass then 'leituras_dia_assinante' else 'leituras_dia_teste' end);
  insert into public.uso_leituras(user_id, dia, qtd) values (auth.uid(), v_dia, n)
  on conflict (user_id, dia) do update set qtd = public.uso_leituras.qtd + n
  returning qtd into v_total;
  if v_total > v_lim then
    raise exception '%', case when v_ass
      then 'Limite diário de leitura atingido (' || v_lim || ' cards). Volte amanhã.'
      else 'No teste grátis dá para abrir até ' || v_lim || ' cards por dia. Assine para continuar estudando.' end
      using errcode = 'P0001';
  end if;
end $$;

-- ---------- 2) leitura de conteúdo só por funções ----------
create or replace function public.fila_estudo(p_decks uuid[], p_novos_por_dia int default 20, p_limite int default 200)
returns table(card_id uuid, deck_id uuid, frente text, verso text, novo boolean,
              ease real, intervalo int, repeticoes int, lapsos int, estado text)
language plpgsql volatile security definer set search_path = public
as $$
declare n int; v_novos int := least(greatest(coalesce(p_novos_por_dia, 20), 0), 200); v_lim int := least(greatest(coalesce(p_limite, 200), 1), 300);
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'Sem acesso. Assine para continuar.'; end if;
  return query
  with visiveis as (
    select c.* from public.cards c join public.decks d on d.id = c.deck_id
    where c.deck_id = any(p_decks) and not c.excluido and d.publicado and (d.dono is null or d.dono = auth.uid())
  ),
  vencidos as (
    select c.id, c.deck_id, c.frente, c.verso, false as novo,
           p.ease, p.intervalo, p.repeticoes, p.lapsos, p.estado, p.vencimento as ord
    from public.progresso p join visiveis c on c.id = p.card_id
    where p.user_id = auth.uid() and p.vencimento <= now()
    order by p.vencimento limit v_lim
  ),
  novos_hoje as (
    select count(*) as n from public.progresso p
    where p.user_id = auth.uid() and p.deck_id = any(p_decks)
      and p.criado_em >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'
  ),
  novos as (
    select c.id, c.deck_id, c.frente, c.verso, true as novo,
           2.5::real as ease, 0 as intervalo, 0 as repeticoes, 0 as lapsos, 'aprendendo'::text as estado, null::timestamptz as ord
    from visiveis c
    where not exists (select 1 from public.progresso p where p.user_id = auth.uid() and p.card_id = c.id)
    order by c.ordem
    limit greatest(0, v_novos - (select novos_hoje.n from novos_hoje))
  )
  select v.id, v.deck_id, v.frente, v.verso, v.novo, v.ease, v.intervalo, v.repeticoes, v.lapsos, v.estado from vencidos v
  union all
  select x.id, x.deck_id, x.frente, x.verso, x.novo, x.ease, x.intervalo, x.repeticoes, x.lapsos, x.estado from novos x;
  get diagnostics n = row_count;
  perform public.consumir_leituras(n);
end $$;

create or replace function public.fila_favoritos(p_limite int default 200)
returns table(card_id uuid, deck_id uuid, frente text, verso text, novo boolean,
              ease real, intervalo int, repeticoes int, lapsos int, estado text)
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'Sem acesso. Assine para continuar.'; end if;
  return query
  select c.id, c.deck_id, c.frente, c.verso, p.card_id is null,
         coalesce(p.ease, 2.5::real), coalesce(p.intervalo, 0), coalesce(p.repeticoes, 0), coalesce(p.lapsos, 0), coalesce(p.estado, 'aprendendo')
  from public.favoritos f
  join public.cards c on c.id = f.card_id and not c.excluido
  join public.decks d on d.id = c.deck_id and d.publicado and (d.dono is null or d.dono = auth.uid())
  left join public.progresso p on p.card_id = c.id and p.user_id = auth.uid()
  where f.user_id = auth.uid() and f.ativo
  order by f.criado_em desc
  limit least(greatest(coalesce(p_limite, 200), 1), 300);
  get diagnostics n = row_count;
  perform public.consumir_leituras(n);
end $$;

-- Busca: devolve só um trecho da pergunta (sem resposta) e não gasta cota; a resposta sai por ver_card
create or replace function public.buscar_cards(p_termo text default '', p_somente_favoritos boolean default false, p_limite int default 60)
returns table(card_id uuid, deck_id uuid, deck text, frente text, verso text, favorito boolean,
              estado text, vencimento timestamptz, intervalo int)
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'Sem acesso. Assine para continuar.'; end if;
  return query
  select c.id, c.deck_id, public.nome_exibido(d),
         left(trim(regexp_replace(regexp_replace(c.frente, '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g')), 300),
         null::text, coalesce(f.ativo, false), p.estado, p.vencimento, p.intervalo
  from public.cards c
  join public.decks d on d.id = c.deck_id and d.publicado and (d.dono is null or d.dono = auth.uid())
  left join public.favoritos f on f.card_id = c.id and f.user_id = auth.uid()
  left join public.progresso p on p.card_id = c.id and p.user_id = auth.uid()
  where not c.excluido
    and (not p_somente_favoritos or coalesce(f.ativo, false))
    and (coalesce(trim(p_termo), '') = '' or c.frente ilike '%' || p_termo || '%' or c.verso ilike '%' || p_termo || '%'
         or public.nome_exibido(d) ilike '%' || p_termo || '%')
  order by d.nome, c.ordem
  limit least(greatest(coalesce(p_limite, 60), 1), 60);
end $$;

create or replace function public.ver_card(p_card uuid)
returns table(card_id uuid, deck text, frente text, verso text)
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'Sem acesso. Assine para continuar.'; end if;
  return query
  select c.id, public.nome_exibido(d), c.frente, c.verso
  from public.cards c join public.decks d on d.id = c.deck_id and d.publicado and (d.dono is null or d.dono = auth.uid())
  where c.id = p_card and not c.excluido;
  get diagnostics n = row_count;
  perform public.consumir_leituras(n);
end $$;

create or replace function public.card_do_dia(p_salto int default 0)
returns table(card_id uuid, deck text, frente text, verso text)
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if auth.uid() is null or not public.tem_acesso() then raise exception 'Sem acesso. Assine para continuar.'; end if;
  return query
  select c.id, d.nome, c.frente, c.verso
  from public.cards c join public.decks d on d.id = c.deck_id and d.publicado and d.dono is null
  where not c.excluido
  order by md5(c.id::text || (now() at time zone 'America/Sao_Paulo')::date::text || least(greatest(coalesce(p_salto, 0), 0), 50)::text)
  limit 1;
  get diagnostics n = row_count;
  perform public.consumir_leituras(n);
end $$;

-- Cards de um deck do próprio aluno (conteúdo dele: não gasta cota)
create or replace function public.cards_do_meu_deck(p_deck uuid)
returns table(id uuid, frente text, verso text)
language sql stable security definer set search_path = public
as $$
  select c.id, c.frente, c.verso from public.cards c join public.decks d on d.id = c.deck_id
  where c.deck_id = p_deck and d.dono = auth.uid() and d.publicado and not c.excluido
  order by c.ordem;
$$;

revoke execute on function public.fila_estudo(uuid[], int, int), public.fila_favoritos(int), public.buscar_cards(text, boolean, int),
  public.ver_card(uuid), public.card_do_dia(int), public.cards_do_meu_deck(uuid), public.eh_assinante(), public.consumir_leituras(int)
  from public, anon;
grant execute on function public.fila_estudo(uuid[], int, int), public.fila_favoritos(int), public.buscar_cards(text, boolean, int),
  public.ver_card(uuid), public.card_do_dia(int), public.cards_do_meu_deck(uuid) to authenticated;
revoke execute on function public.consumir_leituras(int), public.eh_assinante() from authenticated;

-- Funções antigas que não são mais usadas pelo app
revoke execute on function public.resumo_decks() from public, anon, authenticated;

-- Extensão http (usada só em testes internos): ninguém de fora executa
do $$ declare f record; begin
  for f in select p.oid::regprocedure as fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           join pg_depend dep on dep.objid = p.oid join pg_extension e on e.oid = dep.refobjid
           where e.extname = 'http' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.fn);
  end loop;
end $$;

-- Dados pessoais no log de webhooks: guarda só o necessário (sem CPF, telefone, endereço)
update public.webhook_log
   set payload = payload - 'Customer' || jsonb_build_object('Customer', jsonb_build_object(
         'email', payload->'Customer'->>'email', 'full_name', payload->'Customer'->>'full_name'))
 where payload ? 'Customer';

-- Bucket de mídia: só imagens/áudio comuns, até 15 MB (sem HTML/SVG no domínio público)
update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','image/bmp','image/avif','audio/mpeg','audio/ogg','audio/wav','audio/mp4'],
  file_size_limit = 15728640 where id = 'midia';
