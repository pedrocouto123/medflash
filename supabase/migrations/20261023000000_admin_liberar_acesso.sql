-- =====================================================================
-- Administração: os sócios liberam acesso de cortesia (1 ano) por e-mail,
-- direto no Perfil do app, e veem a lista de acessos liberados à mão.
-- =====================================================================

-- Quem é administrador (só o servidor lê; para incluir alguém, insira o e-mail aqui)
create table if not exists public.administradores (
  email     text primary key check (email = lower(email)),
  criado_em timestamptz not null default now()
);
alter table public.administradores enable row level security;  -- sem políticas: só o servidor acessa
revoke all on public.administradores from anon, authenticated;

insert into public.administradores(email) values
  ('pedricout@gmail.com'), ('julincf12@hotmail.com'), ('reisp2553@gmail.com')
on conflict (email) do nothing;

-- Registro de quem liberou o acesso
alter table public.assinaturas add column if not exists liberado_por text;

-- Administrador = conta logada com e-mail confirmado que está na tabela
create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from auth.users u join public.administradores a on a.email = lower(u.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null
  );
$$;

-- Libera 1 ano de acesso (plano "cortesia") para um e-mail, tenha a pessoa conta ou não.
-- Não encurta um acesso que já vale por mais tempo (ex.: assinatura anual recém-comprada).
create or replace function public.admin_liberar_acesso(p_email text)
returns table(email text, expira_em timestamptz, alterado boolean)
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_ate   timestamptz := now() + interval '1 year';
  v_admin text;
  v_atual record;
begin
  if not public.eh_admin() then raise exception 'Apenas administradores podem liberar acesso.' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'E-mail inválido.' using errcode = 'P0001';
  end if;
  select lower(u.email) into v_admin from auth.users u where u.id = auth.uid();

  select a.status, a.expira_em into v_atual from public.assinaturas a where a.email = v_email;
  if found and v_atual.status in ('ativa', 'atrasada', 'cancelada') and (v_atual.expira_em is null or v_atual.expira_em >= v_ate) then
    return query select v_email, v_atual.expira_em, false;
    return;
  end if;

  insert into public.assinaturas as a (email, user_id, status, plano, expira_em, kiwify_assinatura, kiwify_pedido, liberado_por, atualizado_em)
  values (v_email, (select u.id from auth.users u where lower(u.email) = v_email limit 1), 'ativa', 'cortesia', v_ate, null, null, v_admin, now())
  on conflict on constraint assinaturas_pkey do update set
    user_id = coalesce(a.user_id, excluded.user_id), status = 'ativa', plano = 'cortesia', expira_em = v_ate,
    kiwify_assinatura = null, kiwify_pedido = null, liberado_por = v_admin, atualizado_em = now();

  return query select v_email, v_ate, true;
end $$;

-- Acessos liberados à mão (equipe e cortesias), mais recentes primeiro
create or replace function public.admin_listar_liberados()
returns table(email text, plano text, expira_em timestamptz, liberado_por text, tem_conta boolean, atualizado_em timestamptz)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.eh_admin() then raise exception 'Apenas administradores podem ver esta lista.' using errcode = '42501'; end if;
  return query
  select a.email, a.plano, a.expira_em, a.liberado_por,
         exists (select 1 from auth.users u where lower(u.email) = a.email), a.atualizado_em
  from public.assinaturas a
  where a.kiwify_assinatura is null and a.status = 'ativa'
  order by a.atualizado_em desc
  limit 500;
end $$;

revoke execute on function public.eh_admin(), public.admin_liberar_acesso(text), public.admin_listar_liberados() from public, anon;
grant execute on function public.eh_admin(), public.admin_liberar_acesso(text), public.admin_listar_liberados() to authenticated;
