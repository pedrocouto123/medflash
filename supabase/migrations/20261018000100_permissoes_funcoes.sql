-- Fecha as funções para quem não está logado (o Postgres libera EXECUTE para PUBLIC por padrão,
-- o que inclui o papel anon da API do Supabase).
revoke execute on function public.tem_acesso(), public.minha_assinatura(), public.dispositivo_valido(text),
  public.registrar_dispositivo(text, text),
  public.resumo_decks(), public.fila_estudo(uuid[], int, int),
  public.responder_card(uuid, int, real, int, int, int, text, timestamptz),
  public.minhas_estatisticas(int), public.revisoes_por_dia(int)
  from public, anon;

grant execute on function public.registrar_dispositivo(text, text) to authenticated;

-- Função de gatilho: ninguém chama pela API
revoke execute on function public.vincular_assinatura() from public, anon, authenticated;

-- Novas funções criadas no schema public não ficam abertas para anon por padrão
alter default privileges in schema public revoke execute on functions from public, anon;
