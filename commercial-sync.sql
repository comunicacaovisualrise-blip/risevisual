create table public.rise_kit_quotes (
  id text primary key check (id ~ '^kit-[0-9a-f-]{36}$'),
  customer_id uuid not null references public.profiles(id),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  filtered_at timestamptz,
  order_id uuid unique references public.orders(id)
);

create table public.rise_crm_deals (
  id bigint primary key,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  revision integer not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.rise_kit_quotes enable row level security;
alter table public.rise_crm_deals enable row level security;
revoke all on public.rise_kit_quotes, public.rise_crm_deals from public, anon, authenticated;
grant select on public.rise_kit_quotes to authenticated;
grant insert (id,customer_id,payload) on public.rise_kit_quotes to authenticated;
grant update (read_at,filtered_at,order_id) on public.rise_kit_quotes to authenticated;
grant select,insert,update on public.rise_crm_deals to authenticated;

create policy "Admins read kit quotes" on public.rise_kit_quotes
for select to authenticated using ((select private.is_admin()));
create policy "Customers submit their quotes" on public.rise_kit_quotes
for insert to authenticated with check (customer_id = (select auth.uid()));
create policy "Admins manage quote outcomes" on public.rise_kit_quotes
for update to authenticated using ((select private.is_admin()))
with check ((select private.is_admin()));
create policy "Admins manage opportunities" on public.rise_crm_deals
for all to authenticated using ((select private.is_admin()))
with check ((select private.is_admin()));

create function private.convert_rise_kit_quote(quote_id text)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  quote public.rise_kit_quotes;
  buyer public.profiles;
  created public.orders;
  entry jsonb;
  freight numeric;
  computed numeric;
  item_total numeric;
  item_quantity integer;
  first_item uuid;
  inserted_item uuid;
  reference jsonb;
  reference_position integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  select * into quote from public.rise_kit_quotes q where q.id = quote_id for update;
  if not found then raise exception 'Orçamento indisponível.'; end if;
  if quote.order_id is not null then
    return (select o.order_number from public.orders o where o.id = quote.order_id);
  end if;
  select * into strict buyer from public.profiles p where p.id = quote.customer_id;
  if jsonb_typeof(quote.payload->'items') is distinct from 'array'
    or jsonb_array_length(quote.payload->'items') not between 1 and 100 then
    raise exception 'Produtos do orçamento inválidos.';
  end if;
  freight := (quote.payload->>'freight')::numeric;
  computed := freight;
  for entry in select value from jsonb_array_elements(quote.payload->'items') loop
    item_total := round((entry->>'sale')::numeric + coalesce((entry->>'design')::numeric,0),2);
    if item_total is null or item_total < 0 or item_total > 1000000
      or coalesce(entry->>'name','') = '' then
      raise exception 'Revise os produtos e valores do orçamento.';
    end if;
    computed := computed + item_total;
  end loop;
  if freight is null or freight < 0 or computed > 1000000
    or computed is distinct from (quote.payload->>'total')::numeric then
    raise exception 'Revise o total e o frete do orçamento.';
  end if;

  insert into public.orders (customer_id,customer_name,customer_company,customer_email,
    customer_phone,status,payment_status,total,shipping_amount,shipping_address,
    delivery_status,delivery_method,internal_notes)
  values (buyer.id,buyer.full_name,buyer.company_name,buyer.email,buyer.phone,
    'Pagamento pendente','pending',computed,freight,
    jsonb_build_object('zip',quote.payload->>'cep'),'pending','delivery',
    'Orçamento do kit ' || quote.id)
  returning * into created;

  for entry in select value from jsonb_array_elements(quote.payload->'items') loop
    item_quantity := coalesce((entry->'selection'->>'quantity')::integer,1) * (entry->>'count')::integer;
    item_total := round((entry->>'sale')::numeric + coalesce((entry->>'design')::numeric,0),2);
    insert into public.order_items (order_id,product_id,product_name,quantity,unit_price,configuration)
    values (created.id,
      (select p.id from public.products p where p.legacy_id::text = entry->>'id'),
      entry->>'name',item_quantity,item_total,
      (coalesce(entry->'selection','{}'::jsonb) - array['costTotal','markup','source']) ||
      jsonb_build_object('legacy_product_id',entry->'id','spec',entry->>'configuration',
        'quantity',item_quantity,'productionDays',entry->'productionDays'))
    returning id into inserted_item;
    first_item := coalesce(first_item,inserted_item);
  end loop;

  for reference in select value
    from jsonb_array_elements(coalesce(quote.payload->'references','[]'::jsonb)) loop
    if reference->>'path' like buyer.id::text || '/quotes/' || quote.id || '/reference-%'
      and reference->>'type' in ('image/jpeg','image/png','image/webp','image/gif')
      and exists (select 1 from storage.objects s
        where s.bucket_id = 'rise-order-files' and s.name = reference->>'path') then
      insert into public.order_artworks
        (order_item_id,uploaded_by,bucket_path,file_name,mime_type,artwork_role,position)
      values (first_item,buyer.id,reference->>'path',coalesce(reference->>'name','Referência'),
        reference->>'type','reference',reference_position);
      reference_position := reference_position + 1;
    end if;
  end loop;

  update public.rise_kit_quotes q set order_id = created.id, read_at = coalesce(q.read_at,now())
  where q.id = quote_id;
  return created.order_number;
end;
$$;

revoke all on function private.convert_rise_kit_quote(text) from public, anon;
grant execute on function private.convert_rise_kit_quote(text) to authenticated;

create function public.convert_rise_kit_quote(quote_id text)
returns bigint language sql security invoker set search_path = ''
as $$ select private.convert_rise_kit_quote(quote_id); $$;

revoke all on function public.convert_rise_kit_quote(text) from public, anon;
grant execute on function public.convert_rise_kit_quote(text) to authenticated;

create function private.convert_rise_crm_deal(deal_id bigint)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  deal public.rise_crm_deals;
  buyer public.profiles;
  created public.orders;
  negotiated numeric;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  select * into deal from public.rise_crm_deals d where d.id = deal_id for update;
  if not found then raise exception 'Negociação indisponível.'; end if;
  if nullif(deal.payload->>'orderId','') is not null then
    return (deal.payload->>'orderId')::bigint;
  end if;
  if deal.payload->>'stage' = '4' then raise exception 'Reabra a negociação antes de converter.'; end if;
  select * into buyer from public.profiles p where p.id = nullif(deal.payload->>'customerId','')::uuid;
  if not found then raise exception 'Vincule um cliente cadastrado antes de converter.'; end if;
  negotiated := (deal.payload->>'value')::numeric;
  if negotiated is null or negotiated <= 0 or negotiated > 1000000 then
    raise exception 'Confira o valor negociado.';
  end if;

  insert into public.orders (customer_id,customer_name,customer_company,customer_email,
    customer_phone,status,payment_status,total,shipping_amount,shipping_address,
    delivery_status,delivery_method,internal_notes)
  values (buyer.id,buyer.full_name,buyer.company_name,buyer.email,buyer.phone,
    'Pagamento pendente','pending',negotiated,0,coalesce(buyer.details->'address','{}'::jsonb),
    'pending','delivery',coalesce(deal.payload->>'notes',''))
  returning * into created;

  insert into public.order_items (order_id,product_name,quantity,unit_price,configuration)
  values (created.id,coalesce(nullif(deal.payload->>'name',''),'Negociação comercial'),1,negotiated,
    jsonb_build_object('spec',deal.payload->>'notes','crm_deal_id',deal_id));

  update public.rise_crm_deals d set
    payload = deal.payload || jsonb_build_object('stage',3,'orderId',created.order_number,
      'reminderDone',true,'history',coalesce(deal.payload->'history','[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('type','Venda concluída','at',now(),
        'text','Convertida em pedido #' || created.order_number,'author','Administrador'))),
    revision = d.revision + 1, updated_at = now()
  where d.id = deal_id;
  return created.order_number;
end;
$$;

revoke all on function private.convert_rise_crm_deal(bigint) from public, anon;
grant execute on function private.convert_rise_crm_deal(bigint) to authenticated;

create function public.convert_rise_crm_deal(deal_id bigint)
returns bigint language sql security invoker set search_path = ''
as $$ select private.convert_rise_crm_deal(deal_id); $$;

revoke all on function public.convert_rise_crm_deal(bigint) from public, anon;
grant execute on function public.convert_rise_crm_deal(bigint) to authenticated;
