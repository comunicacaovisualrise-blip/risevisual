alter table public.rise_kit_quotes
  add column quote_number bigint generated always as identity,
  add column commercial_stage text not null default 'sent'
    check (commercial_stage in ('sent','negotiating','lost')),
  add constraint rise_kit_quotes_quote_number_key unique (quote_number);

update public.rise_kit_quotes set commercial_stage='lost'
where filtered_at is not null and order_id is null;

grant update (commercial_stage) on public.rise_kit_quotes to authenticated;

create function private.rise_my_quotes()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',q.id,'number',q.quote_number,'createdAt',q.created_at,
      'stage',case when q.order_id is not null then 'won' else q.commercial_stage end,
      'orderNumber',o.order_number,
      'total',q.payload->'total','freight',q.payload->'freight','design',q.payload->'design',
      'items',(select coalesce(jsonb_agg(jsonb_build_object(
        'name',item->'name','configuration',item->'configuration',
        'count',item->'count','sale',item->'sale','design',item->'design'
      )),'[]'::jsonb)
      from jsonb_array_elements(case when jsonb_typeof(q.payload->'items')='array'
        then q.payload->'items' else '[]'::jsonb end) item)
    ) order by q.created_at desc
  ),'[]'::jsonb)
  from public.rise_kit_quotes q
  left join public.orders o on o.id=q.order_id and o.archived_at is null
  where q.customer_id=auth.uid();
$$;

revoke all on function private.rise_my_quotes() from public, anon;
grant execute on function private.rise_my_quotes() to authenticated;
create function public.rise_my_quotes()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.rise_my_quotes(); $$;
revoke all on function public.rise_my_quotes() from public, anon;
grant execute on function public.rise_my_quotes() to authenticated;
