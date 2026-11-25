alter table public.orders
  add column archived_at timestamptz,
  add column archived_by uuid references public.profiles(id),
  add column delivery_confirmation jsonb,
  add column manual_payment jsonb,
  add column customer_payment_receipt jsonb;

create policy "Archived orders visible only to admins" on public.orders
as restrictive for select to authenticated
using (archived_at is null or (select private.is_admin()));

create function private.rise_order_operation(target_id uuid, operation text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  target public.orders;
  actor uuid := auth.uid();
  administrator boolean := coalesce(private.is_admin(),false);
  stamp timestamptz := now();
  event_name text;
  event_title text;
begin
  select * into target from public.orders o where o.id = target_id for update;
  if not found or actor is null or (not administrator and target.customer_id is distinct from actor) then
    raise exception 'Pedido indisponível.' using errcode = '42501';
  end if;

  if operation = 'confirm_delivery' then
    if target.archived_at is not null then raise exception 'Pedido arquivado.'; end if;
    if target.delivery_confirmation is not null then return; end if;
    if target.status not in ('Enviado','Em rota') and not (administrator and target.status = 'Concluído') then
      raise exception 'O pedido ainda não está disponível para confirmar a entrega.';
    end if;
    update public.orders set status = 'Concluído', delivery_status = 'delivered',
      delivery_confirmation = jsonb_build_object('at',stamp,'previousStatus',target.status,
        'actorRole',case when administrator then 'admin' else 'customer' end,
        'actorName',case when administrator then 'Administrador RISE' else target.customer_name end,
        'customerId',target.customer_id)
    where id = target_id;
    event_name := 'delivery_confirmed';
    event_title := 'Entrega confirmada';
  elsif operation = 'archive' or operation = 'restore' then
    if not administrator then raise exception 'Acesso administrativo necessário.' using errcode = '42501'; end if;
    if operation = 'archive' then
      if target.archived_at is not null then return; end if;
      if target.status not in ('Pagamento pendente','Arte pendente')
        or coalesce(target.review_decision,'Aguardando análise') <> 'Aguardando análise'
        or jsonb_path_exists(target.review_history, '$[*] ? (@.decision == "Aceito")')
        or exists (select 1 from public.order_items i join public.final_art_reviews a on a.order_item_id=i.id
          where i.order_id=target_id and a.approved_at is not null)
      then raise exception 'Somente pedidos pendentes sem aprovação podem ser arquivados.'; end if;
      update public.orders set archived_at = stamp, archived_by = actor where id = target_id;
      event_name := 'order_archived';
      event_title := 'Pedido arquivado';
    else
      if target.archived_at is null then return; end if;
      update public.orders set archived_at = null, archived_by = null where id = target_id;
      event_name := 'order_restored';
      event_title := 'Pedido restaurado';
    end if;
  else raise exception 'Operação desconhecida.';
  end if;

  insert into public.order_events (order_id,actor_id,audience,event_type,title,body,payload)
  values (target_id,actor,case when operation = 'confirm_delivery' then 'both' else 'admin' end,
    event_name,event_title,event_title,jsonb_build_object('operation',operation,'at',stamp));
end;
$$;

revoke all on function private.rise_order_operation(uuid,text) from public, anon;
grant execute on function private.rise_order_operation(uuid,text) to authenticated;

create function public.rise_order_operation(target_id uuid, operation text)
returns void language sql security invoker set search_path = ''
as $$ select private.rise_order_operation(target_id,operation); $$;

revoke all on function public.rise_order_operation(uuid,text) from public, anon;
grant execute on function public.rise_order_operation(uuid,text) to authenticated;

create table public.rise_billing_drafts (
  order_id uuid primary key references public.orders(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.rise_billing_drafts enable row level security;
revoke all on public.rise_billing_drafts from public, anon, authenticated;
grant select,insert,update on public.rise_billing_drafts to authenticated;
create policy "Admins manage billing drafts" on public.rise_billing_drafts
for all to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));

create function private.submit_rise_payment_receipt(target_id uuid, file_path text, file_name text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  target public.orders;
  actor uuid := auth.uid();
  object_metadata jsonb;
begin
  select * into target from public.orders o where o.id = target_id for update;
  if not found or actor is null or target.customer_id is distinct from actor
    or target.archived_at is not null or target.payment_status in ('paid','refunded') then
    raise exception 'Pedido indisponível.' using errcode = '42501';
  end if;
  if not starts_with(file_path,actor::text || '/receipts/' || target_id::text || '/')
    or length(btrim(coalesce(file_name,''))) not between 1 and 255 then
    raise exception 'Arquivo inválido.';
  end if;
  select s.metadata into object_metadata from storage.objects s
  where s.bucket_id = 'rise-order-files' and s.name = file_path;
  if not found or coalesce(object_metadata->>'mimetype','') not in
    ('image/jpeg','image/png','image/webp','application/pdf')
    or coalesce((object_metadata->>'size')::bigint,0) not between 1 and 10485760 then
    raise exception 'Use JPG, PNG, WebP ou PDF de até 10 MB.';
  end if;
  if target.customer_payment_receipt->>'path' = file_path then return; end if;
  update public.orders set payment_status = 'proof_sent',
    customer_payment_receipt = jsonb_build_object('key','receipt:' || file_path,'path',file_path,
      'name',file_name,'type',object_metadata->>'mimetype','submittedAt',now(),'reviewStatus','pending')
  where id = target_id;
  insert into public.order_events (order_id,actor_id,audience,event_type,title,body,payload)
  values (target_id,actor,'both','payment_receipt_submitted','Comprovante recebido',
    'Comprovante enviado para conferência pela RISE.','{}'::jsonb);
end;
$$;

revoke all on function private.submit_rise_payment_receipt(uuid,text,text) from public, anon;
grant execute on function private.submit_rise_payment_receipt(uuid,text,text) to authenticated;
create function public.submit_rise_payment_receipt(target_id uuid,file_path text,file_name text)
returns void language sql security invoker set search_path = ''
as $$ select private.submit_rise_payment_receipt(target_id,file_path,file_name); $$;
revoke all on function public.submit_rise_payment_receipt(uuid,text,text) from public, anon;
grant execute on function public.submit_rise_payment_receipt(uuid,text,text) to authenticated;

alter table public.rise_kit_quotes
  add column imported_by uuid references public.profiles(id),
  add column legacy_id text unique;

create function private.import_rise_kit_quote(quote_id text, source_id text, fields jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  buyer uuid;
  linked_order uuid;
  quote_data jsonb;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  if length(coalesce(source_id,'')) not between 1 and 160 or jsonb_typeof(fields) <> 'object' then
    raise exception 'Registro antigo inválido.';
  end if;
  if exists(select 1 from public.rise_kit_quotes q where q.legacy_id = source_id) then return; end if;
  select p.id into buyer from public.profiles p where p.role = 'customer'
    and lower(p.email) = lower(fields->'contact'->>'email');
  if buyer is null then raise exception 'O cliente do orçamento precisa estar cadastrado.'; end if;
  if coalesce(fields->>'orderId','') <> '' then
    select o.id into linked_order from public.orders o where o.customer_id = buyer
      and o.order_number::text = fields->>'orderId';
    if linked_order is null then raise exception 'O pedido antigo vinculado precisa ser conferido antes da importação.'; end if;
  end if;
  quote_data := fields - array['id','orderId','customerId','remote','readAt','status','outcomeAt'];
  insert into public.rise_kit_quotes (id,customer_id,payload,imported_by,legacy_id,created_at,read_at,filtered_at,order_id)
  values (quote_id,buyer,quote_data,auth.uid(),source_id,coalesce((fields->>'createdAt')::timestamptz,now()),
    (fields->>'readAt')::timestamptz,case when fields->>'status'='filtered'
      then coalesce((fields->>'outcomeAt')::timestamptz,now()) else null end,linked_order)
  on conflict (legacy_id) do nothing;
end;
$$;
revoke all on function private.import_rise_kit_quote(text,text,jsonb) from public, anon;
grant execute on function private.import_rise_kit_quote(text,text,jsonb) to authenticated;
create function public.import_rise_kit_quote(quote_id text,source_id text,fields jsonb)
returns void language sql security invoker set search_path = ''
as $$ select private.import_rise_kit_quote(quote_id,source_id,fields); $$;
revoke all on function public.import_rise_kit_quote(text,text,jsonb) from public, anon;
grant execute on function public.import_rise_kit_quote(text,text,jsonb) to authenticated;
