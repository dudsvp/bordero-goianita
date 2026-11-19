-- ============================================================
--  Borderô GOIANITA — banco do Painel de Entregas (Supabase)
--  Rodar inteiro no SQL Editor do Supabase. Pode rodar de novo sem quebrar.
--
--  Segurança:
--   • anon (gerador, sem login): SÓ chama registrar_bordero(). Não lê nada.
--   • authenticated (central/Karinne): lê e atualiza borderôs, lê e anota eventos,
--     envia e vê fotos de comprovante. Ninguém apaga nada (não existe policy de delete).
-- ============================================================

-- ---------- Tabelas ----------
create table if not exists public.borderos (
  id                 uuid primary key default gen_random_uuid(),
  chave              text not null unique,          -- md5(pedido+endereço+itens): evita duplicar regeração idêntica
  numero_pedido      text not null,
  loja               text,
  vendedor           text,
  tipo_entrega       text not null default 'rota' check (tipo_entrega in ('rota','retirada')),
  data_compra        text,                           -- como vem do pedido (dd/mm/aaaa)
  comprador_nome     text,
  comprador_tel      text,
  destinatario       text,
  endereco           text,
  itens              jsonb not null default '[]'::jsonb,   -- [{desc, qty}] — sem valores
  volumes            int,
  obs                text,
  entregador         text,
  lista_presente     boolean not null default false,
  status             text not null default 'gerado'
                     check (status in ('gerado','recebido_central','saiu_entrega',
                                       'entregue','nao_realizada','retirado','cancelado')),
  recebido_por       text,
  data_entrega       date,
  motivo_nao_entrega text,
  foto_path          text,
  origem             text not null default 'gerador',  -- 'gerador' | 'migracao' | 'manual'
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint entregue_exige_recebedor
    check (status <> 'entregue' or (recebido_por is not null and data_entrega is not null)),
  constraint nao_realizada_exige_motivo
    check (status <> 'nao_realizada' or motivo_nao_entrega is not null)
);

create index if not exists borderos_pedido_idx  on public.borderos (numero_pedido);
create index if not exists borderos_status_idx  on public.borderos (status);
create index if not exists borderos_created_idx on public.borderos (created_at desc);

create table if not exists public.eventos (
  id          bigint generated always as identity primary key,
  bordero_id  uuid not null references public.borderos(id) on delete restrict,
  de          text,
  para        text,
  nota        text,
  autor       text,
  created_at  timestamptz not null default now()
);
create index if not exists eventos_bordero_idx on public.eventos (bordero_id, created_at);

-- ---------- Histórico automático de status ----------
create or replace function public.tg_borderos_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_autor text := coalesce(auth.jwt() ->> 'email', 'loja');
  v_nota  text;
begin
  new.updated_at := now();
  if new.status is distinct from old.status then
    v_nota := case new.status
      when 'entregue'      then 'Recebido por: ' || coalesce(new.recebido_por,'')
      when 'nao_realizada' then 'Motivo: ' || coalesce(new.motivo_nao_entrega,'')
      else null end;
    insert into public.eventos (bordero_id, de, para, nota, autor)
    values (new.id, old.status, new.status, v_nota, v_autor);
  end if;
  return new;
end $$;

drop trigger if exists borderos_historico on public.borderos;
create trigger borderos_historico before update on public.borderos
for each row execute function public.tg_borderos_historico();

-- ---------- RPC usada pelo gerador (anon) ----------
-- Recebe o borderô em JSON. Insere se for novo; se for regeração idêntica,
-- só registra um evento "regerado". Retorna {id, novo}.
create or replace function public.registrar_bordero(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pedido text := left(trim(coalesce(p->>'numero_pedido','')), 40);
  v_end    text := left(coalesce(p->>'endereco',''), 600);
  v_itens  jsonb := coalesce(p->'itens', '[]'::jsonb);
  v_chave  text;
  v_id     uuid;
  v_novo   boolean := false;
begin
  if v_pedido = '' then
    raise exception 'numero_pedido obrigatório';
  end if;
  if pg_column_size(p) > 30000 or jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) > 200 then
    raise exception 'borderô inválido ou grande demais';
  end if;

  v_chave := md5(v_pedido || '|' || v_end || '|' || v_itens::text);

  insert into public.borderos (chave, numero_pedido, loja, vendedor, tipo_entrega, data_compra,
                               comprador_nome, comprador_tel, destinatario, endereco, itens,
                               volumes, obs, entregador, lista_presente, origem)
  values (
    v_chave, v_pedido,
    left(p->>'loja', 30),
    left(p->>'vendedor', 120),
    case when p->>'tipo_entrega' = 'retirada' then 'retirada' else 'rota' end,
    left(p->>'data_compra', 20),
    left(p->>'comprador_nome', 200),
    left(p->>'comprador_tel', 40),
    left(p->>'destinatario', 200),
    v_end,
    v_itens,
    least(greatest(coalesce(nullif(p->>'volumes','')::int, 1), 1), 999),
    left(p->>'obs', 500),
    left(p->>'entregador', 120),
    coalesce((p->>'lista_presente')::boolean, false),
    case when p->>'origem' in ('migracao','manual') then p->>'origem' else 'gerador' end
  )
  on conflict (chave) do nothing
  returning id into v_id;

  if v_id is not null then
    v_novo := true;
    insert into public.eventos (bordero_id, de, para, nota, autor)
    values (v_id, null, 'gerado',
            case p->>'origem'
              when 'migracao' then 'Migrado do computador da loja'
              when 'manual'   then 'Cadastrado manualmente na central'
              else null end,
            case when p->>'origem' = 'manual' and auth.role() = 'authenticated'
                 then coalesce(auth.jwt() ->> 'email', 'Central')
                 else coalesce(left(p->>'vendedor',120), 'loja') end);
  else
    select id into v_id from public.borderos where chave = v_chave;
    insert into public.eventos (bordero_id, de, para, nota, autor)
    values (v_id, null, null, 'Borderô gerado novamente', coalesce(left(p->>'vendedor',120), 'loja'));
  end if;

  return jsonb_build_object('id', v_id, 'novo', v_novo);
end $$;

-- ---------- Permissões ----------
alter table public.borderos enable row level security;
alter table public.eventos  enable row level security;

revoke all on public.borderos from anon, public;
revoke all on public.eventos  from anon, public;
grant select, update          on public.borderos to authenticated;
grant select, insert          on public.eventos  to authenticated;

drop policy if exists central_le_borderos    on public.borderos;
drop policy if exists central_edita_borderos on public.borderos;
drop policy if exists central_le_eventos     on public.eventos;
drop policy if exists central_anota_eventos  on public.eventos;

create policy central_le_borderos    on public.borderos for select to authenticated using (true);
create policy central_edita_borderos on public.borderos for update to authenticated using (true) with check (true);
create policy central_le_eventos     on public.eventos  for select to authenticated using (true);
create policy central_anota_eventos  on public.eventos  for insert to authenticated with check (true);

revoke all     on function public.registrar_bordero(jsonb) from public;
grant  execute on function public.registrar_bordero(jsonb) to anon, authenticated;
revoke all     on function public.tg_borderos_historico()  from public, anon, authenticated;

-- ---------- Fotos dos comprovantes (bucket privado) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 8388608,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;

drop policy if exists central_ve_comprovantes     on storage.objects;
drop policy if exists central_envia_comprovantes  on storage.objects;

create policy central_ve_comprovantes    on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes');
create policy central_envia_comprovantes on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes');
