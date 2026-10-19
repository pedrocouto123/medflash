-- =====================================================================
-- Uma tela por vez
-- Cada aba/aparelho gera um código de tela (cabeçalho HTTP x-tela). Ao abrir, a tela
-- "assume" a conta: a anterior perde o acesso na hora e, se for outro aparelho, o login
-- dele é encerrado no servidor (precisa entrar de novo). Conteúdo e progresso só
-- funcionam na tela ativa, conferido no banco (não dá para burlar pelo app).
-- =====================================================================

create table if not exists public.sessao_ativa (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  tela     text not null,
  sessao   uuid,            -- session_id do login (Supabase Auth)
  aparelho text,
  desde    timestamptz not null default now()
);
alter table public.sessao_ativa enable row level security;
create policy "sessao_ativa: dono le" on public.sessao_ativa for select using (user_id = auth.uid());
grant select on public.sessao_ativa to authenticated;
alter table public.sessao_ativa replica identity full;
alter publication supabase_realtime add table public.sessao_ativa;

create or replace function public.minha_tela() returns text
language sql stable set search_path = public
as $$ select nullif(current_setting('request.headers', true)::json ->> 'x-tela', '') $$;

create or replace function public.minha_sessao() returns uuid
language sql stable set search_path = public
as $$ select nullif(auth.jwt() ->> 'session_id', '')::uuid $$;

create or replace function public.tela_ok() returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.sessao_ativa s
    where s.user_id = auth.uid() and s.tela = public.minha_tela()
      and s.sessao is not distinct from public.minha_sessao());
$$;

-- Esta tela assume a conta; os logins em outros aparelhos são encerrados
create or replace function public.assumir_tela(p_aparelho text default null)
returns void language plpgsql volatile security definer set search_path = public
as $$
declare v_tela text := public.minha_tela(); v_sessao uuid := public.minha_sessao();
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  if v_tela is null or length(v_tela) not between 16 and 80 then raise exception 'tela inválida'; end if;
  -- Login encerrado porque a conta foi aberta em outro aparelho: precisa entrar de novo
  if v_sessao is not null and not exists (select 1 from auth.sessions where id = v_sessao and user_id = auth.uid()) then
    raise exception 'SESSAO_ENCERRADA' using errcode = 'P0001';
  end if;
  insert into public.sessao_ativa(user_id, tela, sessao, aparelho, desde)
  values (auth.uid(), v_tela, v_sessao, left(p_aparelho, 120), now())
  on conflict (user_id) do update set tela = excluded.tela, sessao = excluded.sessao, aparelho = excluded.aparelho, desde = now();
  if v_sessao is not null then
    delete from auth.sessions where user_id = auth.uid() and id <> v_sessao;
  end if;
end $$;

-- 'ok' | 'livre' (ninguém assumiu) | 'outra_aba' (mesmo login, outra aba) | 'outro_aparelho'
create or replace function public.estado_tela()
returns table(estado text, aparelho text, desde timestamptz)
language sql stable security definer set search_path = public
as $$
  select case
           when s.user_id is null then 'livre'
           when s.tela = public.minha_tela() and s.sessao is not distinct from public.minha_sessao() then 'ok'
           when s.sessao is not distinct from public.minha_sessao() then 'outra_aba'
           else 'outro_aparelho' end,
         s.aparelho, s.desde
  from (select 1) x left join public.sessao_ativa s on s.user_id = auth.uid();
$$;

-- Acesso = assinatura ou teste grátis válido E esta é a tela ativa
create or replace function public.tem_acesso()
returns boolean language sql stable security definer set search_path = public
as $$
  select public.tela_ok() and (
    exists (
      select 1 from public.assinaturas a
      where (a.user_id = auth.uid() or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
        and a.status in ('ativa', 'atrasada', 'cancelada')
        and (a.expira_em is null or a.expira_em > now())
    ) or exists (
      select 1 from auth.users u
      where u.id = auth.uid()
        and u.created_at + make_interval(hours => (select valor::int from public.config where chave = 'horas_teste')) > now()
    ));
$$;

revoke execute on function public.minha_tela(), public.minha_sessao(), public.tela_ok(), public.assumir_tela(text), public.estado_tela() from public, anon;
grant execute on function public.assumir_tela(text), public.estado_tela() to authenticated;
grant execute on function public.minha_tela(), public.minha_sessao(), public.tela_ok() to authenticated; -- usadas dentro das políticas
-- O controle antigo de aparelhos (até 2 ao mesmo tempo) deixa de ser usado pelo app
revoke execute on function public.registrar_dispositivo(text, text), public.dispositivo_valido(text) from authenticated;
