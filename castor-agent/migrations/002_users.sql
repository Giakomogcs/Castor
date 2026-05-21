-- file: 002_castor_users.sql
-- tier: A
-- purpose: RPCs admin para gerenciar usuários (CRUD) com:
--   * filtro multi-tenant (company_name = 'castor')
--   * role admin|vendedor
--   * proteção contra auto-exclusão e contra rebaixar/excluir o último admin
--   * estados/cidades expostos a partir de raw_user_meta_data
-- depends: 001
-- reversible: no
-- IDEMPOTENTE.

BEGIN;

-- LISTAR ------------------------------------------------------------
DROP FUNCTION IF EXISTS castor_admin_list_users();
CREATE OR REPLACE FUNCTION castor_admin_list_users()
RETURNS TABLE(
  user_id    UUID,
  email      TEXT,
  full_name  TEXT,
  role       TEXT,
  estados    JSONB,
  cidades    JSONB,
  created_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name','')::TEXT,
      COALESCE(u.raw_user_meta_data->>'role','vendedor')::TEXT,
      COALESCE(u.raw_user_meta_data->'estados', '[]'::jsonb),
      COALESCE(u.raw_user_meta_data->'cidades', '[]'::jsonb),
      u.created_at
    FROM auth.users u
    WHERE COALESCE(u.raw_user_meta_data->>'company_name','') = 'castor'
    ORDER BY u.created_at DESC;
END;
$$;

-- CRIAR -------------------------------------------------------------
DROP FUNCTION IF EXISTS castor_admin_create_user(TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION castor_admin_create_user(
  p_email TEXT, p_password TEXT, p_full_name TEXT, p_role TEXT DEFAULT 'vendedor'
)
RETURNS UUID
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  new_id UUID;
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_role NOT IN ('admin','vendedor') THEN
    RAISE EXCEPTION 'Role inválido: %', p_role USING ERRCODE = '22023';
  END IF;
  new_id := gen_random_uuid();
  INSERT INTO auth.users (
    id, instance_id, email, encrypted_password, email_confirmed_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    raw_app_meta_data, raw_user_meta_data, aud, role, created_at, updated_at
  ) VALUES (
    new_id,
    '00000000-0000-0000-0000-000000000000',
    p_email,
    crypt(p_password, gen_salt('bf')),
    NOW(), '', '', '', '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_full_name, 'role', p_role, 'company_name', 'castor'),
    'authenticated', 'authenticated', NOW(), NOW()
  );
  INSERT INTO auth.identities (
    id, user_id, identity_data, provider, provider_id,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(),
    new_id,
    jsonb_build_object('sub', new_id::text, 'email', p_email, 'email_verified', true, 'phone_verified', false),
    'email', new_id::text, NOW(), NOW(), NOW()
  );
  RETURN new_id;
END;
$$;

-- ATUALIZAR ---------------------------------------------------------
DROP FUNCTION IF EXISTS castor_admin_update_user(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION castor_admin_update_user(
  p_user_id UUID, p_full_name TEXT, p_role TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  new_meta     JSONB;
  current_role TEXT;
  admin_count  INT;
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('admin','vendedor') THEN
    RAISE EXCEPTION 'Role inválido: %', p_role USING ERRCODE = '22023';
  END IF;
  IF p_user_id = auth.uid() AND p_role IS NOT NULL AND p_role <> 'admin' THEN
    RAISE EXCEPTION 'Você não pode rebaixar a própria conta.' USING ERRCODE = '22023';
  END IF;
  IF p_role = 'vendedor' THEN
    SELECT raw_user_meta_data->>'role' INTO current_role FROM auth.users WHERE id = p_user_id;
    IF current_role = 'admin' THEN
      SELECT COUNT(*) INTO admin_count FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin';
      IF admin_count <= 1 THEN
        RAISE EXCEPTION 'Não é possível rebaixar o último administrador.' USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
  new_meta := jsonb_build_object('full_name', p_full_name);
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
     SET raw_user_meta_data = COALESCE(raw_user_meta_data,'{}'::jsonb) || new_meta,
         updated_at = NOW()
   WHERE id = p_user_id;
END;
$$;

-- EXCLUIR -----------------------------------------------------------
DROP FUNCTION IF EXISTS castor_admin_delete_user(UUID);
CREATE OR REPLACE FUNCTION castor_admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  admin_count INT;
  target_role TEXT;
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Você não pode excluir a própria conta.' USING ERRCODE = '22023';
  END IF;
  SELECT raw_user_meta_data->>'role' INTO target_role FROM auth.users WHERE id = p_user_id;
  IF target_role = 'admin' THEN
    SELECT COUNT(*) INTO admin_count FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin';
    IF admin_count <= 1 THEN
      RAISE EXCEPTION 'Não é possível excluir o último administrador.' USING ERRCODE = '22023';
    END IF;
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

-- CONFIRMAR EMAIL ---------------------------------------------------
CREATE OR REPLACE FUNCTION castor_admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT castor_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE auth.users SET email_confirmed_at = NOW(), updated_at = NOW() WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION castor_admin_list_users()                              TO authenticated;
GRANT EXECUTE ON FUNCTION castor_admin_create_user(TEXT, TEXT, TEXT, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION castor_admin_update_user(UUID, TEXT, TEXT)             TO authenticated;
GRANT EXECUTE ON FUNCTION castor_admin_delete_user(UUID)                         TO authenticated;
GRANT EXECUTE ON FUNCTION castor_admin_confirm_user(UUID)                        TO authenticated;

INSERT INTO castor_schema_migrations(version) VALUES ('002_users') ON CONFLICT DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
