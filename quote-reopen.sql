create or replace function private.rise_set_quote_stage(target_id text, next_stage text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  quote public.rise_kit_quotes;
  linked_order public.orders;
begin
  if actor is null or private.is_admin() is not true then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  if next_stage is null or next_stage not in ('sent','negotiating','lost') then
    raise exception 'Status comercial inválido.';
  end if;
  select * into quote from public.rise_kit_quotes q
    where q.id=target_id and q.deleted_at is null for update;
  if not found then raise exception 'Orçamento indisponível para alteração.'; end if;
  if quote.order_id is not null then
    select * into strict linked_order from public.orders o
      where o.id=quote.order_id for update;
    if linked_order.payment_status is distinct from 'pending'
      or nullif(linked_order.manual_payment->>'confirmedAt','') is not null
      or linked_order.status is distinct from 'Pagamento pendente' then
      raise exception 'Só é possível reabrir uma venda com pedido aguardando pagamento.';
    end if;
    update public.orders set status='Cancelado',
      archived_at=coalesce(archived_at,now()), archived_by=coalesce(archived_by,actor)
    where id=linked_order.id;
  end if;
  update public.rise_kit_quotes q set commercial_stage=next_stage, order_id=null,
    filtered_at=case when next_stage='lost' then coalesce(q.filtered_at,now()) else null end,
    read_at=coalesce(q.read_at,now())
  where q.id=target_id;
end;
$$;
