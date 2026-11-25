CREATE OR REPLACE FUNCTION public.create_rise_checkout(request_id uuid, customer jsonb, items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  saved public.orders;
  line jsonb;
  product public.products;
  price numeric;
  total_price numeric := 0;
  lines jsonb := '[]'::jsonb;
  qty integer;
  artwork_colors jsonb;
  artwork_keep_colors boolean;
  delivery_freight numeric;
begin
  if actor is null or request_id is null then raise exception 'Sessão ou tentativa inválida'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text || ':' || request_id::text,0));
  select * into saved from public.orders where customer_id=actor and checkout_request_id=request_id;
  if not found then
    if jsonb_typeof(items) is distinct from 'array' then raise exception 'Itens inválidos'; end if;
    if jsonb_array_length(items) not between 1 and 50 then raise exception 'Itens inválidos'; end if;
    for line in select value from jsonb_array_elements(items) loop
      select * into product from public.products p where p.legacy_id = line->>'product_id' and p.active
        and not exists(select 1 from public.site_settings s where s.setting_key='product_visibility_'||p.legacy_id and s.value->'active'='false'::jsonb);
      if not found then raise exception 'Produto indisponível'; end if;
      if jsonb_typeof(line->'variant') is distinct from 'array' then raise exception 'Variação inválida'; end if;
      if jsonb_array_length(line->'variant') <> 9 then raise exception 'Variação inválida'; end if;
      qty := (line->'variant'->>6)::integer;
      if qty is null or qty < 1 then raise exception 'Quantidade inválida'; end if;
      select (entry.value #>> '{}')::numeric into price
      from public.site_settings s cross join lateral jsonb_each(s.value) as entry
      where s.setting_key='sale_prices_'||product.legacy_id
        and (case when left(entry.key,1)='[' then entry.key::jsonb end)=line->'variant'
        and jsonb_typeof(entry.value)='number';
      if price is null or price <= 0 then raise exception 'Variação sem preço publicado'; end if;
      if line->'design'='true'::jsonb then price := price + 45; end if;
      if (line->>'expected_total')::numeric is distinct from price then raise exception 'O preço mudou. Atualize o carrinho e confira novamente.'; end if;
      select coalesce(jsonb_agg(lower(color) order by position),'[]'::jsonb) into artwork_colors
      from (select color,position from jsonb_array_elements_text(
        case when jsonb_typeof(line->'artwork_colors')='array' then line->'artwork_colors' else '[]'::jsonb end
      ) with ordinality as c(color,position) where color ~ '^#[0-9a-fA-F]{6}$' order by position limit 24) selected;
      artwork_keep_colors := coalesce(line->'artwork_keep_colors'='true'::jsonb,false);
      total_price := total_price + price;
      lines := lines || jsonb_build_array(jsonb_build_object('product_id',product.id,'name',product.name,'legacy_id',product.legacy_id,'checkout_index',jsonb_array_length(lines),'quantity',qty,'line_price',price,'variant',line->'variant','design',line->'design','artwork_colors',artwork_colors,'artwork_keep_colors',artwork_keep_colors));
    end loop;
    select (value->>'freight')::numeric into delivery_freight from public.site_settings where setting_key='checkout_delivery' and jsonb_typeof(value->'freight')='number';
    if delivery_freight is null or delivery_freight < 0 then raise exception 'Frete oficial indisponível'; end if;
    if customer->>'delivery_method' is distinct from 'delivery' then raise exception 'Selecione entrega'; end if;
    if (customer->>'expected_total')::numeric is distinct from total_price + delivery_freight then raise exception 'O total mudou. Revise o carrinho e o frete.'; end if;
    insert into public.orders(customer_id,checkout_request_id,customer_name,customer_company,customer_email,customer_phone,shipping_address,delivery_method,shipping_amount,total)
    values(actor,request_id,left(coalesce(customer->>'name',''),150),left(coalesce(customer->>'company',''),150),coalesce(auth.jwt()->>'email',''),left(coalesce(customer->>'phone',''),40),coalesce(customer->'address','{}'::jsonb),'delivery',delivery_freight,total_price + delivery_freight)
    returning * into saved;
    insert into public.order_items(order_id,product_id,product_name,quantity,unit_price,configuration)
    select saved.id,(value->>'product_id')::uuid,value->>'name',(value->>'quantity')::int,
      (value->>'line_price')::numeric,jsonb_build_object('variant',value->'variant','design',value->'design','artwork_colors',value->'artwork_colors','artwork_keep_colors',value->'artwork_keep_colors','legacy_product_id',(value->>'legacy_id')::integer,'checkout_index',(value->>'checkout_index')::integer,'model',value->'variant'->>0,'size',value->'variant'->>1,'material',value->'variant'->>2,'printing',value->'variant'->>3,'coating',value->'variant'->>4,'finish',value->'variant'->>5,'quantity',(value->>'quantity')::integer)
    from jsonb_array_elements(lines);
  end if;
  return jsonb_build_object('id',saved.id,'order_number',saved.order_number,'total',saved.total,'status',saved.status);
end;
$function$;
