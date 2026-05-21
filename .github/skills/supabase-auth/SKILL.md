---
name: supabase-auth
description: "Implement end-to-end Supabase authentication: login/logout, session persistence (including sandboxed iframes), role-based UI (admin vs viewer), and admin user CRUD via SECURITY DEFINER RPCs. USE WHEN the user asks to add auth, build a login screen, manage users, enforce admin-only actions, create auth migrations, guard RPCs by role, or fix lost-session / localStorage issues in embedded webhook HTML. Agnostic across companies — prefix, roles, labels and URLs are parameters."
argument-hint: "Provide: project prefix (e.g. acme_), admin role name, viewer role name, Supabase URL/anon key location"
---

# Supabase Auth Playbook

Playbook for shipping a complete Supabase-based auth layer into any single-page / vanilla HTML app (or a framework app). Covers database, frontend integration, role enforcement and deployment quirks (self-hosted, sandboxed iframes).

## When to Use

Load this skill when the user asks to:

- Add login / logout to a project using Supabase
- Implement user management (list / create / edit / delete) from the UI
- Enforce admin-only vs read-only (viewer) permissions
- Write Supabase SQL migrations for auth helpers / RPCs / RLS
- Debug "session is lost after reload", "localStorage blocked", "NavigatorLockAcquireTimeoutError", or auth inside an embedded/webhook HTML page
- Seed a first admin user on a self-hosted Supabase

## Do NOT Use For

- Generic Postgres schema design unrelated to auth
- OAuth social login flows (this playbook is email+password first; social is a follow-up extension)
- Fixing Supabase infra (Docker, networking) — this is application-level

## Parameters (ask before generating code)

Before writing files, confirm these with the user. Defaults are safe fallbacks.

| Param               | Example                                  | Default         |
| ------------------- | ---------------------------------------- | --------------- |
| `PREFIX`            | `acme_`, `sameka_`                       | `app_`          |
| `ADMIN_ROLE`        | `admin`                                  | `admin`         |
| `VIEWER_ROLE`       | `visualizador`, `viewer`                 | `viewer`        |
| `DEFAULT_ROLE`      | `viewer`                                 | `VIEWER_ROLE`   |
| `STORAGE_KEY`       | `acme-auth`                              | `${PREFIX}auth` |
| `SUPABASE_URL`      | `https://xxx.supabase.co`                | —               |
| `SUPABASE_ANON_KEY` | `eyJhbG...`                              | —               |
| `UI_LANG`           | `pt-BR`, `en`                            | `en`            |
| `DEPLOYMENT`        | `managed` (supabase.com) / `self-hosted` | `managed`       |

All SQL object names **MUST** be namespaced with `PREFIX` to avoid collisions in shared databases.

## Architecture Decision: Profiles Table vs `raw_user_meta_data`

| Approach                                | Pros                                                        | Cons                                                                         | Choose when                                     |
| --------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------- |
| **`raw_user_meta_data.role`** (simpler) | No extra table, fewer migrations, no triggers, RLS unneeded | Cannot query/join easily; role lives only on `auth.users`; weaker validation | Small apps, single-tenant, admin UI only        |
| **`${PREFIX}profiles` table** (robust)  | Joinable, RLS-enforced, CHECK constraints, trigger-synced   | More migrations, extra moving parts                                          | Multi-role, reporting, cross-table joins, audit |

See [references/database.md](./references/database.md) for both options. Default to **metadata approach** unless the user needs joins or RLS on other tables keyed to role.

## Procedure

### Step 1 — Gather parameters

Ask the user for the params above. Confirm `PREFIX` and role names; these appear in every SQL object and cannot be renamed cheaply later.

### Step 2 — Write SQL migrations

Copy the relevant templates from [assets/migrations/](./assets/migrations/) and replace `{{PREFIX}}`, `{{ADMIN_ROLE}}`, `{{VIEWER_ROLE}}`, `{{DEFAULT_ROLE}}`.

Minimum set (metadata approach):

1. `001_user_crud_functions.sql` — RPCs `list/confirm/update/delete_user`
2. `002_add_roles.sql` — adds `role` column to RPC signatures
3. `003_admin_guards.sql` — adds `is_admin()` helper and guards every RPC

Optional (profiles approach):

1. `001_auth_up.sql` — profiles table + triggers + RLS + RPCs
2. `002_seed_admin.sql` — seed first admin user (self-hosted only)

Always end migrations with `NOTIFY pgrst, 'reload schema';` so PostgREST picks up the new signatures.

See [references/database.md](./references/database.md) for the full rationale of each block (SECURITY DEFINER, `search_path`, CHECK constraints, RLS policies, admin guards, "cannot delete last admin" invariant).

### Step 3 — Bootstrap first admin

- **Managed Supabase**: Dashboard → Auth → Users → Add user → then run:
  ```sql
  UPDATE auth.users
  SET raw_user_meta_data = raw_user_meta_data || jsonb_build_object('role', '{{ADMIN_ROLE}}')
  WHERE email = 'admin@example.com';
  ```
- **Self-hosted**: run [assets/migrations/002_seed_admin.sql](./assets/migrations/002_seed_admin.sql) (inserts into `auth.users` + `auth.identities`; requires `pgcrypto`/`crypt`).

### Step 4 — Frontend integration

1. Include the Supabase JS SDK (`@supabase/supabase-js@2`) via CDN or npm.
2. Drop in [assets/auth-storage.js](./assets/auth-storage.js) — resilient storage with localStorage → cookies → memory fallback. **Required** if the app runs inside an iframe or webhook-embedded HTML.
3. Drop in [assets/iframe-polyfills.js](./assets/iframe-polyfills.js) — polyfills `localStorage`, `sessionStorage` and `navigator.locks` for sandboxed contexts. Load **before** the Supabase SDK.
4. Drop in [assets/auth-controller.js](./assets/auth-controller.js) — login form handler, session detection, `onAuthStateChange`, role-based UI helper (`applyRoleUI`).
5. Drop in [assets/user-management.js](./assets/user-management.js) — calls the RPCs and renders a table + modal for create/edit/delete.

See [references/frontend.md](./references/frontend.md) for wiring (DOM IDs expected, CSS hooks, the `handleSession` lifecycle).

### Step 5 — Role enforcement (defense in depth)

Every sensitive action must be guarded at **two** layers:

1. **UI**: hide/disable admin controls via `applyRoleUI()` based on `user_metadata.role`.
2. **Database**: every `SECURITY DEFINER` RPC starts with
   ```sql
   IF NOT {{PREFIX}}is_admin() THEN
     RAISE EXCEPTION 'Access denied: admin only.' USING ERRCODE = '42501';
   END IF;
   ```

Never trust the UI check alone — a viewer can call any exposed RPC from the browser console.

### Step 6 — Verify

Run the checks in [references/verification.md](./references/verification.md):

- Login as admin, viewer, and anonymous — confirm UI and RPC behavior per role.
- Reload the page in a normal tab, then in an iframe, then in a sandboxed iframe — session must survive the first two; log an explicit diagnostic in the third.
- Try to delete the last admin — must fail with the invariant message.
- Remove `role` from admin's metadata and retry RPCs — must return 42501.

## Common Pitfalls

- **`NOTIFY pgrst, 'reload schema';` missing** — new RPC is invisible to the client until the schema cache is reloaded. Always append it to every migration.
- **`search_path` not set** on `SECURITY DEFINER` — opens a privilege-escalation vector. Always `SET search_path = auth, public` (or just `public`).
- **DROP + CREATE without signature** — if you change RPC parameters, `DROP FUNCTION` must include the old arg types, otherwise PostgREST keeps exposing the stale version.
- **Sandboxed iframe** (`<iframe sandbox>` without `allow-same-origin`) — the browser treats it as an opaque origin; **no** persistent storage works. The diagnostic block in `auth-storage.js` detects and logs this; session persistence is impossible — tell the user to add `allow-same-origin` or navigate top-level.
- **`navigator.locks` SecurityError** — Supabase v2 uses Web Locks for token refresh; sandboxed contexts throw. Override via the `lock` option in `createClient` (see `auth-controller.js`) AND polyfill `navigator.locks` at boot.
- **Self-hosted seed without `auth.identities` row** — GoTrue refuses the login ("Invalid login credentials") even though `auth.users` has the row. Always insert the matching identity.
- **Deleting an admin = locking yourself out** — enforce "cannot delete/demote the last admin" inside `delete_user` / `update_user`.
- **`raw_user_meta_data` can be self-edited by the user** via `auth.updateUser({ data })`. If you use the metadata approach, protect `role` server-side: either switch to the profiles-table approach, or override `auth.updateUser` calls to strip `role` (see `references/database.md` §metadata-hardening).

## File Map

- [SKILL.md](./SKILL.md) — this file
- [references/database.md](./references/database.md) — SQL rationale, both approaches, hardening notes
- [references/frontend.md](./references/frontend.md) — HTML structure, DOM IDs, lifecycle
- [references/verification.md](./references/verification.md) — manual & SQL checks
- [assets/migrations/001_user_crud_functions.sql](./assets/migrations/001_user_crud_functions.sql)
- [assets/migrations/002_add_roles.sql](./assets/migrations/002_add_roles.sql)
- [assets/migrations/003_admin_guards.sql](./assets/migrations/003_admin_guards.sql)
- [assets/migrations/001_auth_profiles_up.sql](./assets/migrations/001_auth_profiles_up.sql)
- [assets/migrations/002_seed_admin.sql](./assets/migrations/002_seed_admin.sql)
- [assets/iframe-polyfills.js](./assets/iframe-polyfills.js)
- [assets/auth-storage.js](./assets/auth-storage.js)
- [assets/auth-controller.js](./assets/auth-controller.js)
- [assets/user-management.js](./assets/user-management.js)
