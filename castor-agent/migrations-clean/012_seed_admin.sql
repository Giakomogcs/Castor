-- file: 012_seed_admin.sql
-- tier: A
-- purpose: Seed do admin padrão (admin@castor.com.br / @Admin123). Idempotente — se já existir,
--   apenas garante role=admin/company_name=castor e email confirmado.
-- depends: 001, 002
-- ATENÇÃO: altere a senha após o primeiro login.

BEGIN;

DO $$
DECLARE
  v_email     TEXT := lower('admin@castor.com.br');
  v_password  TEXT := '@Admin123';
  v_full_name TEXT := 'Administrador Castor';
  v_user_id   UUID;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
      id, instance_id, email, encrypted_password, email_confirmed_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
    ) VALUES (
      v_user_id,
      '00000000-0000-0000-0000-000000000000',
      v_email,
      crypt(v_password, gen_salt('bf')),
      NOW(), '', '', '', '',
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name',    v_full_name,
        'role',         'admin',
        'company_name', 'castor',
        'estados',      jsonb_build_array('TODOS'),
        'cidades',      jsonb_build_array('TODAS')
      ),
      'authenticated', 'authenticated', NOW(), NOW()
    );

    INSERT INTO auth.identities (
      id, user_id, identity_data, provider, provider_id,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(),
      v_user_id,
      jsonb_build_object(
        'sub',            v_user_id::text,
        'email',          v_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email', v_user_id::text, NOW(), NOW(), NOW()
    );

    RAISE NOTICE 'Castor: admin padrão criado (%)', v_email;
  ELSE
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
                              || jsonb_build_object('role','admin','company_name','castor'),
           email_confirmed_at = COALESCE(email_confirmed_at, NOW()),
           aud                = COALESCE(NULLIF(aud,''),  'authenticated'),
           role               = COALESCE(NULLIF(role,''), 'authenticated'),
           updated_at         = NOW()
     WHERE id = v_user_id;
    RAISE NOTICE 'Castor: admin padrão já existia (%), garantido role=admin', v_email;
  END IF;
END
$$;

INSERT INTO castor_schema_migrations(version)
VALUES ('012_seed_admin') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ========================== DOWN (comentado) ==========================
-- BEGIN;
-- DELETE FROM auth.identities WHERE user_id IN (SELECT id FROM auth.users WHERE email = 'admin@castor.com.br');
-- DELETE FROM auth.users WHERE email = 'admin@castor.com.br';
-- COMMIT;
