-- =============================================
-- Optional approach B: Profiles table
-- Single migration: table + trigger + RLS + RPCs + grants.
-- Replace {{PREFIX}}, {{ADMIN_ROLE}}, {{VIEWER_ROLE}}, {{DEFAULT_ROLE}}.
-- =============================================

-- 1) TABLE --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.{{PREFIX}}profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name  TEXT NOT NULL DEFAULT '',
  role       TEXT NOT NULL DEFAULT '{{DEFAULT_ROLE}}'
               CHECK (role IN ('{{ADMIN_ROLE}}', '{{VIEWER_ROLE}}')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_{{PREFIX}}profiles_role
  ON public.{{PREFIX}}profiles(role);

-- 2) TRIGGERS -----------------------------------------------
CREATE OR REPLACE FUNCTION public.{{PREFIX}}handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.{{PREFIX}}profiles (id, full_name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'role', '{{DEFAULT_ROLE}}')
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS {{PREFIX}}on_auth_user_created ON auth.users;
CREATE TRIGGER {{PREFIX}}on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.{{PREFIX}}handle_new_user();

CREATE OR REPLACE FUNCTION public.{{PREFIX}}handle_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS {{PREFIX}}on_profile_updated ON public.{{PREFIX}}profiles;
CREATE TRIGGER {{PREFIX}}on_profile_updated
BEFORE UPDATE ON public.{{PREFIX}}profiles
FOR EACH ROW EXECUTE FUNCTION public.{{PREFIX}}handle_updated_at();

-- 3) RLS ----------------------------------------------------
ALTER TABLE public.{{PREFIX}}profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "{{PREFIX}}users_view_own"
  ON public.{{PREFIX}}profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "{{PREFIX}}admins_view_all"
  ON public.{{PREFIX}}profiles FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}'));

CREATE POLICY "{{PREFIX}}admins_update_all"
  ON public.{{PREFIX}}profiles FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}'));

CREATE POLICY "{{PREFIX}}admins_delete_all"
  ON public.{{PREFIX}}profiles FOR DELETE
  USING (EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}'));

CREATE POLICY "{{PREFIX}}admins_insert"
  ON public.{{PREFIX}}profiles FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                       WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}'));

GRANT USAGE ON SCHEMA public TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.{{PREFIX}}profiles TO authenticated;

-- 4) RPCs ---------------------------------------------------
-- Mirrors the metadata RPCs but reads from the profiles table.
CREATE OR REPLACE FUNCTION public.{{PREFIX}}admin_list_users()
RETURNS TABLE(user_id UUID, email TEXT, full_name TEXT, role TEXT, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}') THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.id, u.email::TEXT, p.full_name, p.role, p.created_at
    FROM public.{{PREFIX}}profiles p
    JOIN auth.users u ON u.id = p.id
    ORDER BY p.created_at DESC;
END; $$;

CREATE OR REPLACE FUNCTION public.{{PREFIX}}admin_update_user(
  p_user_id UUID, p_full_name TEXT DEFAULT NULL, p_role TEXT DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}') THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = '42501';
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('{{ADMIN_ROLE}}', '{{VIEWER_ROLE}}') THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;
  IF p_role IS NOT NULL AND p_role <> '{{ADMIN_ROLE}}' THEN
    IF EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                WHERE id = p_user_id AND role = '{{ADMIN_ROLE}}') THEN
      IF (SELECT count(*) FROM public.{{PREFIX}}profiles
           WHERE role = '{{ADMIN_ROLE}}') <= 1 THEN
        RAISE EXCEPTION 'Cannot demote the last administrator.';
      END IF;
    END IF;
  END IF;
  UPDATE public.{{PREFIX}}profiles
  SET full_name = COALESCE(p_full_name, full_name),
      role      = COALESCE(p_role, role)
  WHERE id = p_user_id;
END; $$;

CREATE OR REPLACE FUNCTION public.{{PREFIX}}admin_delete_user(p_user_id UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
                  WHERE id = auth.uid() AND role = '{{ADMIN_ROLE}}') THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot delete your own account.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.{{PREFIX}}profiles
              WHERE id = p_user_id AND role = '{{ADMIN_ROLE}}') THEN
    IF (SELECT count(*) FROM public.{{PREFIX}}profiles
         WHERE role = '{{ADMIN_ROLE}}') <= 1 THEN
      RAISE EXCEPTION 'Cannot delete the last administrator.';
    END IF;
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.{{PREFIX}}admin_list_users()                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.{{PREFIX}}admin_update_user(UUID, TEXT, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.{{PREFIX}}admin_delete_user(UUID)              TO authenticated;

NOTIFY pgrst, 'reload schema';
