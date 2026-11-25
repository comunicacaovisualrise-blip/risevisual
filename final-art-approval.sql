-- Draft for the combined release. The client wiring must ship with this migration.
alter table public.orders
  add column review_decision text check (review_decision in ('Aguardando análise','Aceito','Não aceito')),
  add column review_reason text,
  add column review_history jsonb not null default '[]'::jsonb;

create table public.final_art_reviews (
  order_item_id uuid primary key references public.order_items(id) on delete cascade,
  revision integer not null default 1 check (revision > 0),
  options jsonb not null check (jsonb_typeof(options) = 'array'),
  published_at timestamptz,
  approved_slot integer check (approved_slot between 0 and 2),
  approved_at timestamptz,
  check ((approved_slot is null) = (approved_at is null)),
  check (approved_at is null or published_at is not null),
  check (published_at is null or (
    jsonb_array_length(options) = 3
    and coalesce(options->0->>'path','') <> ''
    and coalesce(options->1->>'path','') <> ''
    and coalesce(options->2->>'path','') <> ''
  ))
);

alter table public.final_art_reviews enable row level security;
revoke all on public.final_art_reviews from public, anon, authenticated;
grant select, insert, update on public.final_art_reviews to authenticated;

create policy "Administrators manage final art reviews"
on public.final_art_reviews for all to authenticated
using ((select private.is_admin()))
with check ((select private.is_admin()));

create policy "Customers read published art for their items"
on public.final_art_reviews for select to authenticated
using (
  published_at is not null and exists (
    select 1 from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.id = final_art_reviews.order_item_id
      and o.customer_id = (select auth.uid())
  )
);

-- Keep final art outside the customer's writable Storage prefix.
create policy "Customers read their published final art files"
on storage.objects for select to authenticated
using (
  bucket_id = 'rise-order-files'
  and exists (
    select 1 from public.final_art_reviews r
    join public.order_items i on i.id = r.order_item_id
    join public.orders o on o.id = i.order_id
    cross join lateral jsonb_array_elements(r.options) as option
    where r.published_at is not null
      and o.customer_id = (select auth.uid())
      and option->>'path' = storage.objects.name
  )
);

create function private.approve_rise_final_art(
  item_id uuid, expected_revision integer, chosen_slot integer, via_whatsapp boolean
) returns public.final_art_reviews
language plpgsql security definer set search_path = ''
as $$
declare
  review public.final_art_reviews;
  buyer uuid;
  target_order uuid;
  order_status text;
  decision text;
  start_day date;
  due_day date;
  work_days integer;
begin
  select o.customer_id, o.status, o.id, o.review_decision into buyer, order_status, target_order, decision
  from public.orders o
  join public.order_items i on i.order_id = o.id
  where i.id = item_id
  for update of o;

  if auth.uid() is null or buyer is null
    or (via_whatsapp is true and not private.is_admin())
    or (via_whatsapp is not true and buyer is distinct from auth.uid()) then
    raise exception 'Pedido indisponível.' using errcode = '42501';
  end if;

  select * into review from public.final_art_reviews r
  where r.order_item_id = item_id for update;

  if not found or review.published_at is null
    or review.revision is distinct from expected_revision
    or chosen_slot is null or chosen_slot not between 0 and 2
    or nullif(review.options->chosen_slot->>'path', '') is null
  then
    raise exception 'As opções de arte mudaram. Reabra o pedido.';
  end if;

  if review.approved_slot = chosen_slot then return review; end if;
  if review.approved_at is not null
    or order_status in ('Cancelado', 'Em produção', 'Enviado', 'Em rota', 'Concluído')
  then
    raise exception 'Este item não está disponível para aprovação.';
  end if;

  update public.final_art_reviews r
  set approved_slot = chosen_slot, approved_at = now()
  where r.order_item_id = item_id
  returning * into review;

  if decision is distinct from 'Não aceito' and not exists (
    select 1 from public.order_items i
    left join public.final_art_reviews r on r.order_item_id = i.id
    where i.order_id = target_order and r.approved_at is null
  ) then
    select coalesce(max(case
      when i.configuration->>'productionDays' ~ '^[0-9]{1,2}$'
      then (i.configuration->>'productionDays')::integer
      else 0 end),0)
    into work_days from public.order_items i where i.order_id = target_order;

    select coalesce(o.production_start_date, (now() at time zone 'America/Sao_Paulo')::date)
    into start_day from public.orders o where o.id = target_order;
    if work_days > 0 then
      select d::date into due_day
      from generate_series(start_day + 1, start_day + 2 * work_days + 7, interval '1 day') d
      where extract(isodow from d) <= 5
      order by d offset (work_days - 1) limit 1;
    end if;

    update public.orders o set
      status = 'Em produção', delivery_status = 'preparing',
      production_start_date = start_day,
      production_due_date = coalesce(o.production_due_date, due_day)
    where o.id = target_order;

  end if;
  insert into public.order_events (order_id,actor_id,audience,event_type,title,body,payload)
  values (target_order,auth.uid(),'both','art_approved','Arte aprovada',
    'Opção ' || (chosen_slot+1) || ' confirmada.',
    jsonb_build_object('item_id',item_id,'revision',expected_revision,'slot',chosen_slot,
      'via_whatsapp',coalesce(via_whatsapp,false)));
  return review;
end;
$$;

revoke all on function private.approve_rise_final_art(uuid, integer, integer, boolean) from public, anon;
grant execute on function private.approve_rise_final_art(uuid, integer, integer, boolean) to authenticated;

create function public.approve_rise_final_art(
  item_id uuid, expected_revision integer, chosen_slot integer, via_whatsapp boolean default false
) returns public.final_art_reviews
language sql security invoker set search_path = ''
as $$
  select private.approve_rise_final_art(item_id, expected_revision, chosen_slot, via_whatsapp);
$$;

revoke all on function public.approve_rise_final_art(uuid, integer, integer, boolean) from public, anon;
grant execute on function public.approve_rise_final_art(uuid, integer, integer, boolean) to authenticated;

create function private.notify_rise_final_art_publication()
returns trigger language plpgsql set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id,title,body,kind)
  select o.customer_id,'Escolha a arte do pedido #' || o.order_number,
    'Confira as três opções para ' || i.product_name || ' em Meus pedidos.',
    'final-art-item'
  from public.order_items i join public.orders o on o.id = i.order_id
  where i.id = new.order_item_id;
  return new;
end;
$$;

create trigger rise_final_art_publication_notice
after update of published_at on public.final_art_reviews
for each row when (old.published_at is null and new.published_at is not null)
execute function private.notify_rise_final_art_publication();

create function private.sync_rise_production_job()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'Em produção' and old.status is distinct from new.status
    and exists (
      select 1 from public.order_items i
      left join public.final_art_reviews r on r.order_item_id = i.id
      where i.order_id = new.id and r.approved_at is null
    )
  then
    raise exception 'Confirme as artes de todos os itens antes de iniciar a produção.';
  end if;

  update public.production_jobs j set
    stage = case new.status
      when 'Pagamento pendente' then 'waiting_payment'
      when 'Arte pendente' then 'waiting_art'
      when 'Em produção' then 'in_production'
      when 'Enviado' then 'shipped'
      when 'Em rota' then 'shipped'
      when 'Concluído' then 'delivered'
      when 'Cancelado' then 'cancelled'
      else j.stage end,
    due_at = new.production_due_date::timestamp at time zone 'America/Sao_Paulo',
    started_at = new.production_start_date::timestamp at time zone 'America/Sao_Paulo',
    completed_at = case when new.status = 'Concluído' then coalesce(j.completed_at,now())
      else j.completed_at end
  where j.order_id = new.id;
  return new;
end;
$$;

create trigger rise_sync_production_job
after update of status, production_start_date, production_due_date on public.orders
for each row execute function private.sync_rise_production_job();
