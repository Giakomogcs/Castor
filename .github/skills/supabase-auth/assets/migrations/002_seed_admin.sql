-- =============================================
-- Seed: first admin user (self-hosted Supabase)
-- Managed Supabase: use Auth → Users → Add user instead.
-- Requires pgcrypto (crypt, gen_salt).
-- Replace the admin_email / admin_password / admin_name / {{ADMIN_ROLE}}.
-- =============================================

DO $$
DECLARE
  new_id          UUID := gen_random_uuid();
  admin_email     TEXT := 'admin@example.com';
  admin_password  TEXT := 'CHANGE_ME_STRONG_PASSWORD';
  admin_name      TEXT := 'Administrator';
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at,
    raw_user_meta_data, raw_app_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) VALUES (
    new_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    admin_email,
    crypt(admin_password, gen_salt('bf')),
    now(),
    jsonb_build_object(
      'sub', new_id::text,
      'email', admin_email,
      'email_verified', true,
      'phone_verified', false,
      'full_name', admin_name,
      'role', '{{ADMIN_ROLE}}'
    ),
    jsonb_build_object('provider', 'email', 'providers', ARRAY['email']),
    now(), now(), '', ''
  );

  -- GoTrue requires a matching identity row for email login
  INSERT INTO auth.identities (
    id, user_id, provider_id, provider,
    identity_data, last_sign_in_at, created_at, updated_at
  ) VALUES (
    new_id, new_id, admin_email, 'email',
    jsonb_build_object(
      'sub', new_id::text,
      'email', admin_email,
      'email_verified', true,
      'phone_verified', false
    ),
    now(), now(), now()
  );
END;
$$;
