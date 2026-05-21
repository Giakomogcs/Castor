# Database Reference

All SQL objects are prefixed with `{{PREFIX}}` so multiple apps can share a single Supabase project.

## Two approaches

### A) Metadata approach (simpler, recommended default)

Role lives in `auth.users.raw_user_meta_data->>'role'`. No extra table.

- Pros: zero schema, no triggers, no RLS.
- Cons: `raw_user_meta_data` is writable by the user via `auth.updateUser({ data })`. Harden by rejecting `role` server-side (see §metadata-hardening) or move to approach B.

Migrations: `001_user_crud_functions.sql` → `002_add_roles.sql` → `003_admin_guards.sql`.

### B) Profiles table approach (robust)

A `{{PREFIX}}profiles` table mirrors `auth.users(id)` with `role`, `full_name`, timestamps.

- Pros: RLS-enforced, `CHECK (role IN (...))`, joinable, safer.
- Cons: more migrations, a trigger to auto-insert the profile on `auth.users` INSERT.

Migration: `001_auth_profiles_up.sql` (single file contains table, trigger, RLS, RPCs, grants).

## Always-on patterns

### `SECURITY DEFINER` + `search_path`

```sql
CREATE OR REPLACE FUNCTION {{PREFIX}}admin_list_users()
RETURNS TABLE (...)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$ ... $$;
```

- `SECURITY DEFINER` runs as the function owner (superuser) — required to touch `auth.users`.
- `SET search_path` is mandatory — without it, a malicious user can shadow a built-in with a schema they own and hijack the elevated session.

### Admin guard

```sql
CREATE OR REPLACE FUNCTION {{PREFIX}}is_admin()
RETURNS BOOLEAN
SECURITY DEFINER SET search_path = auth, public
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role'
       FROM auth.users
      WHERE id = auth.uid()) = '{{ADMIN_ROLE}}',
    false);
$$;
```

Use inside every sensitive RPC:

```sql
IF NOT {{PREFIX}}is_admin() THEN
  RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
END IF;
```

### Invariant: cannot remove the last admin

Inside `admin_update_user` (if new role ≠ admin) and `admin_delete_user`:

```sql
IF EXISTS (SELECT 1 FROM auth.users
           WHERE id = p_user_id AND raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') THEN
  IF (SELECT count(*) FROM auth.users
       WHERE raw_user_meta_data->>'role' = '{{ADMIN_ROLE}}') <= 1 THEN
    RAISE EXCEPTION 'Cannot remove the last administrator.';
  END IF;
END IF;
```

### Schema reload

Every migration ends with:

```sql
NOTIFY pgrst, 'reload schema';
```

Without this, PostgREST caches the old signatures; the UI will get "function does not exist".

## Metadata hardening

If you stay with approach A, block users from writing their own `role`:

```sql
-- Trigger that strips 'role' from user-driven updates
CREATE OR REPLACE FUNCTION {{PREFIX}}prevent_role_self_edit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.raw_user_meta_data ? 'role'
     AND (OLD.raw_user_meta_data->>'role') IS DISTINCT FROM (NEW.raw_user_meta_data->>'role')
     AND NOT {{PREFIX}}is_admin() THEN
    NEW.raw_user_meta_data := NEW.raw_user_meta_data - 'role'
                             || jsonb_build_object('role', OLD.raw_user_meta_data->>'role');
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER {{PREFIX}}on_user_meta_update
BEFORE UPDATE ON auth.users
FOR EACH ROW EXECUTE FUNCTION {{PREFIX}}prevent_role_self_edit();
```

## Self-hosted first-admin seed

Self-hosted Supabase ships no UI to add the first user from an empty DB. Seed by inserting both `auth.users` and `auth.identities` — GoTrue requires the identity row to resolve email login.

Password is hashed with `crypt(password, gen_salt('bf'))` (requires `pgcrypto`).

See [../assets/migrations/002_seed_admin.sql](../assets/migrations/002_seed_admin.sql).

## Grants checklist

For every RPC:

```sql
GRANT EXECUTE ON FUNCTION {{PREFIX}}admin_xxx(...) TO authenticated;
```

`anon` should never be granted admin RPCs. If you expose a self-signup, keep it to `auth.signUp` on the client — never a SECURITY DEFINER with anon grant.
