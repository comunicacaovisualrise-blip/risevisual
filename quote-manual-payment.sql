create function private.rise_register_quote_payment(
  quote_id text, receipt_path text, receipt_name text, payment_method text
) returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  q public.rise_kit_quotes;
  o public.orders;
  number bigint;
  meta jsonb;
  confirmed timestamptz := now();
begin
  if actor is null or private.is_admin() is not true then
    raise exception 'Acesso administrativo necessário.' using errcode='42501';
  end if;
  select * into q from public.rise_kit_quotes k where k.id=quote_id for update;
  if not found then raise exception 'Orçamento indisponível.'; end if;
  if q.order_id is not null then
    select * into strict o from public.orders where id=q.order_id for update;
    if o.payment_status='paid' and o.manual_payment->'receipt'->>'path'=receipt_path then
      return o.order_number;
    end if;
    if o.archived_at is not null or o.status='Cancelado' or o.payment_status in ('paid','refunded') then
      raise exception 'O pedido já tem pagamento registrado ou está indisponível.';
    end if;
  end if;
  if payment_method is null or payment_method not in ('pix','payment_link')
    or receipt_path is null
    or not starts_with(receipt_path,actor::text||'/quote-payments/'||quote_id||'/')
    or length(btrim(coalesce(receipt_name,''))) not between 1 and 255 then
    raise exception 'Confira a forma de pagamento e o comprovante.';
  end if;
  select s.metadata into meta from storage.objects s
  where s.bucket_id='rise-order-files' and s.name=receipt_path;
  if not found or coalesce(meta->>'mimetype','') not in ('image/jpeg','image/png','image/webp','application/pdf')
    or coalesce((meta->>'size')::bigint,0) not between 1 and 10485760 then
    raise exception 'Envie um comprovante JPG, PNG, WebP ou PDF de até 10 MB.';
  end if;
  number := private.convert_rise_kit_quote(quote_id);
  update public.orders set payment_status='paid',
    status=case when status='Pagamento pendente' then 'Arte pendente' else status end,
    review_decision='Aceito',
    review_history=review_history||jsonb_build_array(jsonb_build_object(
      'decision','Aceito','reason','Pagamento manual conferido','at',confirmed)),
    manual_payment=jsonb_build_object('method',payment_method,'installments',1,'confirmedAt',confirmed,
      'receipt',jsonb_build_object('key','receipt:'||receipt_path,'path',receipt_path,
        'name',receipt_name,'type',meta->>'mimetype'))
  where order_number=number returning * into strict o;
  insert into public.order_events(order_id,actor_id,audience,event_type,title,body,payload)
  values(o.id,actor,'both','manual_payment_confirmed','Pagamento confirmado',
    'A RISE confirmou o recebimento do pagamento.',jsonb_build_object('method',payment_method,'at',confirmed));
  return number;
end;
$$;
revoke all on function private.rise_register_quote_payment(text,text,text,text) from public,anon;
grant execute on function private.rise_register_quote_payment(text,text,text,text) to authenticated;
create function public.rise_register_quote_payment(
  quote_id text, receipt_path text, receipt_name text, payment_method text
) returns bigint language sql security invoker set search_path=''
as $$ select private.rise_register_quote_payment(quote_id,receipt_path,receipt_name,payment_method); $$;
revoke all on function public.rise_register_quote_payment(text,text,text,text) from public,anon;
grant execute on function public.rise_register_quote_payment(text,text,text,text) to authenticated;
