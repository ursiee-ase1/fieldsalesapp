-- Agent sign-in without an SMS provider.
--
-- Agents type their phone number; the app and the invite-member function map
-- it to a login email `<digits>@phone.fieldsales.invalid` and use the Email
-- provider. `.invalid` is a reserved TLD (RFC 2606): nobody can own it, so no
-- password-reset email for these accounts can ever be delivered to anyone.

create function app.is_phone_login(p_email text)
returns boolean
language sql immutable set search_path = ''
as $$ select coalesce(lower(p_email) like '%@phone.fieldsales.invalid', false) $$;

-- Phone logins are created by companies, never self-onboarded.
create or replace function public.create_company(p_name text, p_full_name text, p_phone text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_company uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from auth.users
                 where id = v_uid and email is not null and not app.is_phone_login(email)) then
    raise exception 'email_account_required' using errcode = '42501';
  end if;
  if exists (select 1 from public.memberships where user_id = v_uid) then
    raise exception 'already_member' using errcode = '23505';
  end if;

  insert into public.companies (name) values (trim(p_name)) returning id into v_company;

  insert into public.profiles (user_id, full_name, phone_e164)
  values (v_uid, trim(p_full_name),
          case when nullif(trim(p_phone), '') is null then null
               else app.normalize_phone(p_phone) end)
  on conflict (user_id) do update set full_name = excluded.full_name,
                                      phone_e164 = coalesce(excluded.phone_e164, public.profiles.phone_e164);

  insert into public.memberships (company_id, user_id, role, created_by)
  values (v_company, v_uid, 'admin', v_uid);

  perform app.write_audit(v_company, 'company.created', 'company', v_company,
                          null, jsonb_build_object('name', trim(p_name)));
  return v_company;
end;
$$;

-- For invite-member: if a phone login already exists but belongs to no
-- company (e.g. someone signed up with it first), return its id so the
-- function can remove it and create the real account. Returns null when the
-- login is free or genuinely in use.
create function public.admin_orphan_phone_login(p_email text)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select u.id from auth.users u
  where lower(u.email) = lower(p_email)
    and app.is_phone_login(u.email)
    and not exists (select 1 from public.memberships m where m.user_id = u.id)
$$;

revoke all on function public.admin_orphan_phone_login from public, anon, authenticated;
grant execute on function public.admin_orphan_phone_login to service_role;
