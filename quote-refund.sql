alter table public.rise_kit_quotes
  add column refund_record jsonb check (refund_record is null or order_id is not null);

create function private.rise_can_read_refund_receipt(object_name text)
returns boolean language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and exists(
    select 1 from public.rise_kit_quotes q
    where q.customer_id=auth.uid()
      and q.refund_record->'receipt'->>'path'=object_name
  );
$$;
revoke all on function private.rise_can_read_refund_receipt(text) from public,anon;
grant execute on function private.rise_can_read_refund_receipt(text) to authenticated;

create policy "Customers read their refund receipts" on storage.objects
for select to authenticated using (
  bucket_id='rise-order-files'
  and name like '%/quote-refunds/%'
  and private.rise_can_read_refund_receipt(name)
);

create function private.rise_record_quote_refund(target_id text, refund_reason text, receipt_path text, receipt_name text)
returns bigint language plpgsql security definer set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  quote public.rise_kit_quotes;
  sale public.orders;
  meta jsonb;
  at_time timestamptz:=now();
  note text:=btrim(coalesce(refund_reason,''));
begin
  if actor is null or private.is_admin() is not true then
    raise exception 'Acesso administrativo necessário.' using errcode='42501';
  end if;
  select * into quote from public.rise_kit_quotes q where q.id=target_id for update;
  if not found or quote.order_id is null or quote.deleted_at is not null then
    raise exception 'O orçamento precisa estar vinculado a uma venda concluída.';
  end if;
  select * into strict sale from public.orders o where o.id=quote.order_id for update;
  if quote.refund_record is not null then
    if quote.refund_record->'receipt'->>'path'=receipt_path then return sale.order_number; end if;
    raise exception 'O estorno já foi registrado.';
  end if;
  if sale.payment_status is distinct from 'paid' then raise exception 'Este pedido ainda não tem pagamento confirmado.'; end if;
  if length(note) not between 3 and 1000
    or receipt_path is null or not starts_with(receipt_path,actor::text||'/quote-refunds/'||target_id||'/')
    or length(btrim(coalesce(receipt_name,''))) not between 1 and 255 then
    raise exception 'Informe o motivo e anexe o comprovante do estorno.';
  end if;
  select s.metadata into meta from storage.objects s
  where s.bucket_id='rise-order-files' and s.name=receipt_path;
  if not found or coalesce(meta->>'mimetype','') not in ('image/jpeg','image/png','image/webp','application/pdf')
    or coalesce((meta->>'size')::bigint,0) not between 1 and 10485760 then
    raise exception 'Envie um comprovante JPG, PNG, WebP ou PDF de até 10 MB.';
  end if;
  update public.orders set payment_status='refunded',status='Cancelado',delivery_status='cancelled'
  where id=sale.id;
  update public.rise_kit_quotes set commercial_stage='lost',filtered_at=at_time,
    refund_record=jsonb_build_object('reason',note,'at',at_time,'recordedBy',actor,
      'amount',sale.total,'receipt',jsonb_build_object('path',receipt_path,'name',receipt_name,'type',meta->>'mimetype'))
  where id=target_id;
  insert into public.order_events(order_id,actor_id,audience,event_type,title,body,payload)
  values(sale.id,actor,'both','payment_refunded','Pagamento estornado',note,jsonb_build_object('at',at_time,'amount',sale.total));
  return sale.order_number;
end;
$$;
revoke all on function private.rise_record_quote_refund(text,text,text,text) from public,anon;
grant execute on function private.rise_record_quote_refund(text,text,text,text) to authenticated;
create function public.rise_record_quote_refund(target_id text,refund_reason text,receipt_path text,receipt_name text)
returns bigint language sql security invoker set search_path=''
as $$ select private.rise_record_quote_refund(target_id,refund_reason,receipt_path,receipt_name); $$;
revoke all on function public.rise_record_quote_refund(text,text,text,text) from public,anon;
grant execute on function public.rise_record_quote_refund(text,text,text,text) to authenticated;
CREATE OR REPLACE FUNCTION private.rise_my_quotes()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',q.id,'number',q.quote_number,'createdAt',q.created_at,
      'refund',q.refund_record - 'recordedBy',
      'stage',case when q.refund_record is not null then 'refunded' when q.order_id is not null then 'won'
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
