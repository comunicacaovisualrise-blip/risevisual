create function private.create_rise_manual_order(
  request_id uuid, buyer_id uuid, catalog_product_id bigint, negotiated_total numeric, specification text
) returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  buyer public.profiles;
  product public.products;
  created public.orders;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  if request_id is null or buyer_id is null or negotiated_total is null
    or negotiated_total not between 0.01 and 1000000
    or negotiated_total <> round(negotiated_total, 2)
    or length(btrim(coalesce(specification,''))) not between 1 and 4000 then
    raise exception 'Confira cliente, valor e configuração do pedido.';
  end if;

  select * into strict buyer from public.profiles p where p.id = buyer_id and p.role = 'customer';
  select * into strict product from public.products p where p.legacy_id = catalog_product_id::text;
  perform pg_advisory_xact_lock(hashtextextended('rise-manual:' || request_id::text,0));
  select * into created from public.orders o
  where o.checkout_request_id = request_id and o.customer_id = buyer_id;
  if found then return created.order_number; end if;

  insert into public.orders (customer_id,customer_name,customer_company,customer_email,
    customer_phone,status,payment_status,total,shipping_amount,shipping_address,
    delivery_status,delivery_method,checkout_request_id)
  values (buyer.id,buyer.full_name,buyer.company_name,buyer.email,buyer.phone,
    'Pagamento pendente','pending',negotiated_total,0,coalesce(buyer.details->'address','{}'::jsonb),
    'pending','delivery',request_id)
  returning * into created;

  insert into public.order_items (order_id,product_id,product_name,quantity,unit_price,configuration)
  values (created.id,product.id,product.name,1,negotiated_total,
    jsonb_build_object('legacy_product_id',catalog_product_id,'spec',btrim(specification)));
  return created.order_number;
end;
$$;

revoke all on function private.create_rise_manual_order(uuid,uuid,bigint,numeric,text) from public, anon;
grant execute on function private.create_rise_manual_order(uuid,uuid,bigint,numeric,text) to authenticated;

create function public.create_rise_manual_order(
  request_id uuid, buyer_id uuid, catalog_product_id bigint, negotiated_total numeric, specification text
) returns bigint language sql security invoker set search_path = ''
as $$
  select private.create_rise_manual_order(request_id,buyer_id,catalog_product_id,negotiated_total,specification);
$$;

revoke all on function public.create_rise_manual_order(uuid,uuid,bigint,numeric,text) from public, anon;
grant execute on function public.create_rise_manual_order(uuid,uuid,bigint,numeric,text) to authenticated;
