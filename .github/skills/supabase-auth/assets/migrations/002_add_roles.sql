-- =============================================
-- 002: Add role to the CRUD RPCs
-- Run AFTER 001_user_crud_functions.sql.
-- Replace {{PREFIX}}, {{DEFAULT_ROLE}} before running.
-- =============================================

-- =======  UP  ========

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
LANGUAGE sql
STABLE
AS $$
  SELECT
    id AS user_id,
    email::TEXT,
    COALESCE(raw_user_meta_data->>'full_name', '')::TEXT,
    COALESCE(raw_user_meta_data->>'role', '{{DEFAULT_ROLE}}')::TEXT,
    created_at
  FROM auth.users
  ORDER BY created_at DESC;
$$;

DROP FUNCTION IF EXISTS {{PREFIX}}admin_update_user(UUID, TEXT);
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

GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_list_users()                    TO authenticated;
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_update_user(UUID, TEXT, TEXT)   TO authenticated;

NOTIFY pgrst, 'reload schema';
