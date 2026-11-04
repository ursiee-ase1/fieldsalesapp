// Creates an account for a new company member and attaches it to the
// caller's company. Agents sign in with phone + password (mapped to a login
// email, see _shared/phone.ts); managers and admins may use email or phone.
//
// Authorization is decided by the database (public.admin_add_member checks
// the inviter's role); the pre-check here only avoids creating auth users
// that would then be rejected.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders, error, json } from '../_shared/cors.ts';
import { normalizeGhanaPhone, phoneLoginEmail } from '../_shared/phone.ts';

type Role = 'admin' | 'manager' | 'agent';

interface InviteRequest {
  full_name: string;
  role: Role;
  phone?: string;
  email?: string;
  password: string;
  team_id?: string;
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function validate(body: Partial<InviteRequest>): { value?: InviteRequest; problems: string[] } {
  const problems: string[] = [];
  const fullName = body.full_name?.trim() ?? '';
  if (fullName.length < 2) problems.push('full_name is required');
  if (!['admin', 'manager', 'agent'].includes(body.role ?? '')) problems.push('role is invalid');
  if (!body.password || body.password.length < 8) problems.push('password must be at least 8 characters');

  const phone = body.phone ? normalizeGhanaPhone(body.phone) : undefined;
  if (body.phone && !phone) problems.push('phone is not a valid Ghana number');
  const email = body.email?.trim().toLowerCase() || undefined;
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) problems.push('email is invalid');
  if (body.role === 'agent' && !phone) problems.push('agents need a phone number');
  if (!phone && !email) problems.push('phone or email is required');

  if (problems.length) return { problems };
  return {
    problems,
    value: {
      full_name: fullName,
      role: body.role as Role,
      phone: phone ?? undefined,
      email,
      password: body.password!,
      team_id: body.team_id,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return error('method_not_allowed', 'Use POST', 405);

  const jwt = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (!jwt) return error('not_authenticated', 'Missing Authorization header', 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: caller, error: callerError } = await admin.auth.getUser(jwt);
  if (callerError || !caller.user) return error('not_authenticated', 'Invalid session', 401);

  let body: Partial<InviteRequest>;
  try {
    body = await req.json();
  } catch {
    return error('validation_failed', 'Body must be JSON', 400);
  }
  const { value: invite, problems } = validate(body);
  if (!invite) return error('validation_failed', 'Invalid invite', 422, problems);

  const { data: membership } = await admin
    .from('memberships')
    .select('role, status')
    .eq('user_id', caller.user.id)
    .maybeSingle();
  const allowed = membership?.status === 'active' &&
    (membership.role === 'admin' || (membership.role === 'manager' && invite.role === 'agent'));
  if (!allowed) return error('forbidden', 'You cannot invite this role', 403);

  // Members without an email sign in with their phone number, mapped to a
  // login email so no SMS provider is needed. The phone itself lives in the
  // profile.
  const usesPhoneLogin = !invite.email;
  const loginEmail = invite.email ?? phoneLoginEmail(invite.phone!);
  const createAccount = () =>
    admin.auth.admin.createUser({
      email: loginEmail,
      password: invite.password,
      email_confirm: true,
      user_metadata: { full_name: invite.full_name, phone: invite.phone, must_change_password: true },
    });

  let { data: created, error: createError } = await createAccount();
  if (createError && usesPhoneLogin && /already/i.test(createError.message)) {
    // Someone may have signed up with this phone login first. Such accounts
    // can never join a company on their own, so an orphan is safe to replace.
    const { data: orphanId } = await admin.rpc('admin_orphan_phone_login', { p_email: loginEmail });
    if (orphanId) {
      await admin.auth.admin.deleteUser(orphanId as string);
      ({ data: created, error: createError } = await createAccount());
    }
  }
  if (createError || !created.user) {
    const exists = /already/i.test(createError?.message ?? '');
    return error(exists ? 'conflict' : 'auth_error',
      exists ? 'A member with this phone number or email already exists' : 'Could not create the account',
      exists ? 409 : 500, createError?.message);
  }

  const { data: membershipId, error: rpcError } = await admin.rpc('admin_add_member', {
    p_inviter: caller.user.id,
    p_user: created.user.id,
    p_role: invite.role,
    p_full_name: invite.full_name,
    p_phone: invite.phone ?? null,
    p_team: invite.team_id ?? null,
  });
  if (rpcError) {
    // Compensate so a failed invite doesn't leave an orphaned login behind.
    await admin.auth.admin.deleteUser(created.user.id);
    const forbidden = rpcError.code === '42501';
    return error(forbidden ? 'forbidden' : 'validation_failed', rpcError.message, forbidden ? 403 : 422);
  }

  return json({ user_id: created.user.id, membership_id: membershipId }, 201);
});
