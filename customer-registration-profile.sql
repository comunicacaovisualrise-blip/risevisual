create function private.rise_store_registration_profile()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  submitted jsonb:=new.raw_user_meta_data->'rise_registration';
begin
  if submitted is null then return new; end if;
  if jsonb_typeof(submitted)='object' and submitted->>'type' in ('PF','PJ')
    and octet_length(submitted::text)<=8000 then
    update public.profiles
      set details=jsonb_strip_nulls(jsonb_build_object(
        'type',submitted->'type',
        'fullName',submitted->'fullName',
        'legalName',submitted->'legalName',
        'tradeName',submitted->'tradeName',
        'document',submitted->'document',
        'birthDate',submitted->'birthDate',
        'contactName',submitted->'contactName',
        'stateRegistration',submitted->'stateRegistration',
        'taxpayer',submitted->'taxpayer',
        'mobile',submitted->'mobile',
        'phone',submitted->'phone',
        'invoiceEmail',submitted->'invoiceEmail',
        'marketing',submitted->'marketing',
        'address',jsonb_strip_nulls(jsonb_build_object(
          'zip',submitted->'address'->'zip',
          'street',submitted->'address'->'street',
          'number',submitted->'address'->'number',
          'complement',submitted->'address'->'complement',
          'district',submitted->'address'->'district',
          'city',submitted->'address'->'city',
          'uf',submitted->'address'->'uf',
          'country',submitted->'address'->'country',
          'reference',submitted->'address'->'reference'
        ))
      ))
    where id=new.id and role='customer';
  end if;
  update auth.users set raw_user_meta_data=raw_user_meta_data-'rise_registration' where id=new.id;
  return new;
end;
$$;
revoke all on function private.rise_store_registration_profile() from public,anon,authenticated;
create trigger zz_rise_store_registration_profile after insert on auth.users
for each row execute function private.rise_store_registration_profile();
