alter table public.rise_kit_quotes
  add column deleted_at timestamptz,
  add column deleted_by uuid references public.profiles(id),
  add constraint rise_deleted_quote_not_converted check (deleted_at is null or order_id is null);

create function private.rise_guard_deleted_quote()
returns trigger language plpgsql set search_path=''
as $$
begin
  if old.deleted_at is not null then
    raise exception 'Este orçamento foi excluído.';
  end if;
  return new;
end;
$$;

create trigger rise_guard_deleted_quote before update on public.rise_kit_quotes
for each row when (old.deleted_at is not null)
execute function private.rise_guard_deleted_quote();

create function private.rise_delete_quote(target_id text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  quote public.rise_kit_quotes;
begin
  if auth.uid() is null or private.is_admin() is not true then
    raise exception 'Acesso administrativo necessário.' using errcode='42501';
  end if;
  select * into quote from public.rise_kit_quotes q where q.id=target_id for update;
  if not found then raise exception 'Orçamento indisponível.'; end if;
  if quote.order_id is not null then raise exception 'Uma venda concluída não pode ser excluída.'; end if;
  if quote.deleted_at is not null then return; end if;
  update public.rise_kit_quotes set deleted_at=now(),deleted_by=auth.uid() where id=target_id;
end;
$$;
revoke all on function private.rise_delete_quote(text) from public,anon;
grant execute on function private.rise_delete_quote(text) to authenticated;
create function public.rise_delete_quote(target_id text)
returns void language sql security invoker set search_path=''
as $$ select private.rise_delete_quote(target_id); $$;
revoke all on function public.rise_delete_quote(text) from public,anon;
grant execute on function public.rise_delete_quote(text) to authenticated;

CREATE OR REPLACE FUNCTION private.rise_my_quotes()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',q.id,'number',q.quote_number,'createdAt',q.created_at,
      'stage',case when q.order_id is not null then 'won'
        when q.filtered_at is not null then 'lost' else q.commercial_stage end,
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
  where q.customer_id=auth.uid() and q.deleted_at is null;
$function$;
