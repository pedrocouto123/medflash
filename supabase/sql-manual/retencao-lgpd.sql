-- Retenção de dados (LGPD): rode uma vez no SQL Editor do Supabase.
-- Agenda uma limpeza diária às 03:17 (horário de Brasília) que apaga:
--   registros de notificações de pagamento com mais de 12 meses,
--   contagem diária de uso com mais de 90 dias e registros antigos de aparelhos.
create or replace function public.limpar_dados_antigos()
returns void language sql volatile security definer set search_path = public
as $$
  delete from public.webhook_log where recebido_em < now() - interval '12 months';
  delete from public.uso_leituras where dia < current_date - 90;
  delete from public.dispositivos where ultimo_acesso < now() - interval '90 days';
$$;
revoke execute on function public.limpar_dados_antigos() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('limpeza-lgpd-diaria', '17 6 * * *', 'select public.limpar_dados_antigos()');
