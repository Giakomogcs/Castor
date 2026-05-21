-- =============================================
-- 003: Admin-only guards
-- Run AFTER 002_add_roles.sql.
-- Replace {{PREFIX}}, {{ADMIN_ROLE}}, {{DEFAULT_ROLE}} before running.
-- Adds {{PREFIX}}is_admin() and enforces it in every admin RPC.
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION {{PREFIX}}is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role'
       FROM auth.users
      WHERE id = auth.uid()) = '{{ADMIN_ROLE}}',
    false
  );
$$;

DROP FUNCTION IF EXISTS {{PREFIX}}admin_list_users();
CREATE OR REPLACE FUNCTION {{PREFIX}}admin_list_users()
RETURNS TABLE(
  user_id    UUID,
  email      TEXT,
  full_name  TEXT,
  role       TEXT,
  created_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT {{PREFIX}}is_admin() THEN
    RAISE EXCEPTION 'Access denied: admin only.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::TEXT,
      COALESCE(u.raw_user_meta_data->>'role', '{{DEFAULT_ROLE}}')::TEXT,
      u.created_at
    FROM auth.users u
    ORDER BY u.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION {{PREFIX}}admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT {{PREFIX}}is_admin() THEN
    RAISE EXCEPTION 'Access denied: admin only.' USING ERRCODE = '42501';
  END IF;
  UPDATE auth.users
  SET email_confirmed_at = NOW(), updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

DROP FUNCTION IF EXISTS {{PREFIX}}admin_update_user(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION {{PREFIX}}admin_update_user(
  p_user_id   UUID,
  p_full_name TEXT,
  p_role      TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
DECLARE
  new_meta JSONB;
BEGIN
  IF NOT {{PREFIX}}is_admin() THEN
    RAISE EXCEPTION 'Access denied: admin only.' USING ERRCODE = '42501';
  END IF;

  -- Prevent demotion of the last admin
  IF p_role IS NOT NULL AND p_role <> '{{ADMIN_ROLE}}' THEN
    IF EXISTS (SELECT 1 FROM auth.users
               WHERE id = p_user_id
                 AND raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') THEN
      IF (SELECT count(*) FROM auth.users
           WHERE raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') <= 1 THEN
        RAISE EXCEPTION 'Cannot demote the last administrator.';
      END IF;
    END IF;
  END IF;

  new_meta := jsonb_build_object('full_name', p_full_name);
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
  SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || new_meta,
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION {{PREFIX}}admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT {{PREFIX}}is_admin() THEN
    RAISE EXCEPTION 'Access denied: admin only.' USING ERRCODE = '42501';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot delete your own account.';
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users
             WHERE id = p_user_id
               AND raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') THEN
    IF (SELECT count(*) FROM auth.users
         WHERE raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') <= 1 THEN
      RAISE EXCEPTION 'Cannot delete the last administrator.';
    END IF;
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION {{PREFIX}}is_admin()                            TO authenticated;
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_list_users()                    TO authenticated;
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_confirm_user(UUID)              TO authenticated;
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_update_user(UUID, TEXT, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_delete_user(UUID)               TO authenticated;

NOTIFY pgrst, 'reload schema';
