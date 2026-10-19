-- =====================================================================
-- LGPD: direitos do titular dentro do app e retenção de dados
--   meus_dados()           -> exporta tudo o que a plataforma guarda sobre o aluno (art. 18, II e V)
--   Edge Function excluir-conta -> elimina conta e dados de estudo (art. 18, VI); mantém só o registro
--                                  mínimo de pagamento (e-mail, plano, datas) para obrigações legais
--   sql-manual/retencao-lgpd.sql -> retenção: logs de pagamento 12 meses, contagem de uso 90 dias
-- =====================================================================

create or replace function public.meus_dados()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare u uuid := auth.uid(); v_email text;
begin
  if u is null then raise exception 'não autenticado'; end if;
  select email into v_email from auth.users where id = u;
  return jsonb_build_object(
    'gerado_em', now(),
    'controlador', 'Pulse Medcards',
    'conta', (select jsonb_build_object('id', id, 'email', email, 'nome', raw_user_meta_data ->> 'nome',
                'criada_em', created_at, 'ultimo_login', last_sign_in_at, 'aceite_termos', raw_user_meta_data -> 'aceite_termos')
              from auth.users where id = u),
    'assinatura', (select jsonb_agg(jsonb_build_object('plano', plano, 'situacao', status, 'acesso_ate', expira_em,
                     'pedido_kiwify', kiwify_pedido, 'atualizado_em', atualizado_em))
                   from public.assinaturas a where a.user_id = u or lower(a.email) = lower(v_email)),
    'historico_pagamentos', (select jsonb_agg(jsonb_build_object('plano', plano, 'situacao', status, 'acesso_ate', expira_em, 'atualizado_em', atualizado_em) order by atualizado_em)
                             from public.kiwify_assinaturas where lower(email) = lower(v_email)),
    'progresso', (select jsonb_agg(jsonb_build_object('card_id', p.card_id, 'deck', d.nome, 'estado', p.estado, 'intervalo_dias', p.intervalo,
                    'repeticoes', p.repeticoes, 'lapsos', p.lapsos, 'facilidade', p.ease, 'proxima_revisao', p.vencimento, 'ultima_revisao', p.ultima_revisao))
                  from public.progresso p left join public.decks d on d.id = p.deck_id where p.user_id = u),
    'revisoes', (select jsonb_agg(jsonb_build_object('card_id', card_id, 'nota', nota, 'em', revisado_em) order by revisado_em)
                 from public.revisoes where user_id = u),
    'favoritos', (select jsonb_agg(jsonb_build_object('card_id', card_id, 'ativo', ativo, 'desde', criado_em))
                  from public.favoritos where user_id = u),
    'meus_decks', (select jsonb_agg(jsonb_build_object('titulo', coalesce(d.titulo, d.nome), 'criado_em', d.criado_em,
                     'cards', (select jsonb_agg(jsonb_build_object('frente', c.frente, 'verso', c.verso, 'criado_em', c.criado_em) order by c.ordem)
                               from public.cards c where c.deck_id = d.id and not c.excluido)))
                   from public.decks d where d.dono = u and d.publicado),
    'uso_diario', (select jsonb_agg(jsonb_build_object('dia', dia, 'cards_abertos', qtd) order by dia) from public.uso_leituras where user_id = u),
    'tela_conectada', (select jsonb_build_object('aparelho', aparelho, 'desde', desde) from public.sessao_ativa where user_id = u)
  );
end $$;

revoke execute on function public.meus_dados() from public, anon;
grant execute on function public.meus_dados() to authenticated;

-- A exclusão de conta é feita pela Edge Function "excluir-conta" (API de administração do Supabase Auth).
-- A limpeza automática por prazo de retenção fica em supabase/sql-manual/retencao-lgpd.sql.
