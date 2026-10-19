-- Teste grátis de 2 horas a partir da criação da conta + planos mensal e anual da Kiwify.
-- Corte de acesso: fim do dia do vencimento (horário de Brasília). Vence dia 10 -> corta à 00:00 do dia 11.

insert into public.config(chave, valor) values ('horas_teste', '2') on conflict (chave) do nothing;
update public.config set valor = '0' where chave = 'dias_carencia_atraso';

-- Cada assinatura/pedido da Kiwify separadamente (permite ter mensal e anual ao mesmo tempo, na migração)
create table if not exists public.kiwify_assinaturas (
  id            text primary key,          -- subscription_id (ou order_id em compra única)
  email         text not null,
  plano         text not null,             -- mensal | anual
  status        text not null,             -- ativa | atrasada | cancelada | reembolsada
  expira_em     timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists kiwify_assinaturas_email_idx on public.kiwify_assinaturas(lower(email));
alter table public.kiwify_assinaturas enable row level security;  -- sem políticas: só o servidor acessa

-- Consolida as assinaturas da Kiwify de um e-mail na tabela usada pelo app
create or replace function public.recalcular_assinatura(p_email text)
returns void language plpgsql volatile security definer set search_path = public
as $$
declare v record;
begin
  select * into v from public.kiwify_assinaturas
   where lower(email) = lower(p_email) and status in ('ativa', 'atrasada', 'cancelada') and expira_em > now()
   order by expira_em desc limit 1;
  -- Acesso liberado à mão (equipe, cortesia) que dura mais não é substituído
  if exists (select 1 from public.assinaturas a where lower(a.email) = lower(p_email) and a.kiwify_assinatura is null
             and a.status = 'ativa' and (a.expira_em is null or a.expira_em > greatest(coalesce(v.expira_em, now()), now()))) then
    return;
  end if;
  if v.id is not null then
    insert into public.assinaturas(email, status, plano, expira_em, kiwify_assinatura, atualizado_em)
    values (lower(p_email), v.status, v.plano, v.expira_em, v.id, now())
    on conflict (email) do update set status = excluded.status, plano = excluded.plano, expira_em = excluded.expira_em,
      kiwify_assinatura = excluded.kiwify_assinatura, atualizado_em = now();
  else
    -- nenhuma assinatura válida: fica a situação mais recente (vencida, cancelada ou reembolsada)
    insert into public.assinaturas(email, status, plano, expira_em, kiwify_assinatura, atualizado_em)
    select lower(p_email), k.status, k.plano, k.expira_em, k.id, now()
    from public.kiwify_assinaturas k where lower(k.email) = lower(p_email)
    order by k.atualizado_em desc limit 1
    on conflict (email) do update set status = excluded.status, plano = excluded.plano, expira_em = excluded.expira_em,
      kiwify_assinatura = excluded.kiwify_assinatura, atualizado_em = now();
  end if;
  update public.assinaturas a set user_id = u.id from auth.users u
   where lower(a.email) = lower(p_email) and lower(u.email) = lower(p_email) and a.user_id is null;
end $$;

-- Usado pelo webhook para achar a conta de quem pagou
create or replace function public.id_por_email(p_email text)
returns uuid language sql stable security definer set search_path = public
as $$ select id from auth.users where lower(email) = lower(p_email) limit 1 $$;

-- Acesso: assinatura válida OU dentro das horas de teste desde a criação da conta
create or replace function public.tem_acesso()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.assinaturas a
    where (a.user_id = auth.uid() or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
      and a.status in ('ativa', 'atrasada', 'cancelada')
      and (a.expira_em is null or a.expira_em > now())
  ) or exists (
    select 1 from auth.users u
    where u.id = auth.uid()
      and u.created_at + make_interval(hours => (select valor::int from public.config where chave = 'horas_teste')) > now()
  );
$$;

-- Situação completa para o app (assinatura, teste grátis e acesso)
create or replace function public.minha_situacao()
returns table(status text, plano text, expira_em timestamptz, assinante boolean, em_teste boolean, teste_ate timestamptz, acesso boolean)
language plpgsql stable security definer set search_path = public
as $$
declare a record; v_teste timestamptz; v_assinante boolean;
begin
  if auth.uid() is null then return; end if;
  select x.* into a from public.assinaturas x
   where x.user_id = auth.uid() or lower(x.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
   order by x.expira_em desc nulls first limit 1;
  select u.created_at + make_interval(hours => (select valor::int from public.config where chave = 'horas_teste'))
    into v_teste from auth.users u where u.id = auth.uid();
  v_assinante := a.email is not null and a.status in ('ativa', 'atrasada', 'cancelada') and (a.expira_em is null or a.expira_em > now());
  return query select a.status, a.plano, a.expira_em, v_assinante,
    (not v_assinante and v_teste > now()), v_teste, (v_assinante or v_teste > now());
end $$;

revoke execute on function public.recalcular_assinatura(text), public.id_por_email(text) from public, anon, authenticated;
revoke execute on function public.minha_situacao() from public, anon;
grant execute on function public.minha_situacao() to authenticated;
