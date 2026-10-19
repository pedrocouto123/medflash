-- =====================================================================
-- Desempenho: a tela de Decks estourava o tempo limite (8 s) no celular.
-- Causa: painel_decks contava cards sob RLS, e a política de cards chamava
-- tem_acesso() (que agora também confere a tela ativa) uma vez POR CARD (~13 mil).
-- Correção: políticas com (select tem_acesso()) -> avaliado uma vez por consulta;
-- painel_decks e contagem_estados viram SECURITY DEFINER com filtros explícitos
-- (só contam; não devolvem conteúdo). Resultado: 2.900 ms -> ~15 ms.
-- =====================================================================
alter policy "cards: assinantes leem" on public.cards using ((not excluido) and (select public.tem_acesso()) and exists (select 1 from public.decks d where d.id = cards.deck_id and d.publicado and (d.dono is null or d.dono = (select auth.uid()))));
alter policy "favoritos: dono grava" on public.favoritos with check ((user_id = (select auth.uid())) and (select public.tem_acesso()));
alter policy "progresso: dono" on public.progresso using (user_id = (select auth.uid())) with check ((user_id = (select auth.uid())) and (select public.tem_acesso()));
alter policy "revisoes: dono grava" on public.revisoes with check ((user_id = (select auth.uid())) and (select public.tem_acesso()));

create or replace function public.painel_decks()
returns table(id uuid, nome text, descricao text, total bigint, estudados bigint, aprendendo bigint, revisar bigint, maduros bigint, novos_hoje bigint)
language sql stable security definer set search_path = public
as $$
  with eu as (select auth.uid() as uid),
  meus as (
    select p.deck_id,
           count(*) as estudados,
           count(*) filter (where p.estado = 'aprendendo' and p.vencimento <= now()) as aprendendo,
           count(*) filter (where p.estado = 'revisao' and p.vencimento <= now()) as revisar,
           count(*) filter (where p.intervalo >= 21) as maduros,
           count(*) filter (where p.criado_em >= date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') as novos_hoje
    from public.progresso p join public.cards c on c.id = p.card_id and not c.excluido
    where p.user_id = (select uid from eu)
    group by p.deck_id
  ),
  totais as (select c.deck_id, count(*) as total from public.cards c where not c.excluido group by c.deck_id)
  select d.id, public.nome_exibido(d), d.descricao,
         coalesce(t.total, 0), coalesce(m.estudados, 0), coalesce(m.aprendendo, 0), coalesce(m.revisar, 0), coalesce(m.maduros, 0), coalesce(m.novos_hoje, 0)
  from public.decks d
  left join totais t on t.deck_id = d.id
  left join meus m on m.deck_id = d.id
  where d.publicado and (d.dono is null or d.dono = (select uid from eu))
  order by (d.dono is null), d.ordem, public.nome_exibido(d);
$$;

create or replace function public.contagem_estados()
returns table(novos bigint, aprendendo bigint, jovens bigint, maduros bigint)
language sql stable security definer set search_path = public
as $$
  select
    (select count(*) from public.cards c join public.decks d on d.id = c.deck_id and d.publicado and (d.dono is null or d.dono = auth.uid())
      where not c.excluido and not exists (select 1 from public.progresso p where p.card_id = c.id and p.user_id = auth.uid())),
    count(*) filter (where p.estado = 'aprendendo'),
    count(*) filter (where p.estado = 'revisao' and p.intervalo < 21),
    count(*) filter (where p.estado = 'revisao' and p.intervalo >= 21)
  from public.progresso p where p.user_id = auth.uid();
$$;
revoke execute on function public.painel_decks(), public.contagem_estados() from public, anon;
grant execute on function public.painel_decks(), public.contagem_estados() to authenticated;
