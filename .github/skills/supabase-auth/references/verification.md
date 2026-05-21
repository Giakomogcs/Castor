# Verification Checklist

Run through these after every auth-related migration or deploy.

## Functional

- [ ] Anonymous user → redirected to login overlay on every route.
- [ ] Wrong password → generic error ("Invalid credentials"), no leak about email existence.
- [ ] Correct login → session persists across tab close/reopen (non-iframe).
- [ ] Logout → session cleared, overlay reappears.
- [ ] Viewer role → admin UI hidden, `addUserBtn` invisible.
- [ ] Viewer calls `{{PREFIX}}admin_list_users()` from DevTools console → 42501 error.
- [ ] Admin can list / create / edit / delete users.
- [ ] Cannot delete own account → explicit error.
- [ ] Cannot demote/delete the last admin → explicit error.

## SQL sanity

```sql
-- 1. Every admin RPC starts with is_admin() check
SELECT proname
FROM pg_proc
WHERE proname LIKE '{{PREFIX}}admin\_%'
  AND prosrc NOT LIKE '%{{PREFIX}}is_admin()%';
-- expected: 0 rows

-- 2. Every SECURITY DEFINER function has search_path set
SELECT proname
FROM pg_proc
WHERE prosecdef = true
  AND proname LIKE '{{PREFIX}}%'
  AND NOT (proconfig::text ILIKE '%search_path%');
-- expected: 0 rows

-- 3. Grants are 'authenticated' only (not 'anon' or 'public')
SELECT p.proname, r.rolname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
LEFT JOIN LATERAL aclexplode(p.proacl) acl ON true
LEFT JOIN pg_roles r ON r.oid = acl.grantee
WHERE p.proname LIKE '{{PREFIX}}admin\_%'
  AND r.rolname IN ('anon', 'public');
-- expected: 0 rows

-- 4. PostgREST schema is reloaded
-- Check that new RPCs are callable; otherwise re-run:
NOTIFY pgrst, 'reload schema';
```

## Storage / iframe

Paste this snippet in DevTools:

```js
console.log(
  "ls:",
  (() => {
    try {
      localStorage.setItem("x", "1")
      return localStorage.getItem("x") === "1"
    } catch (e) {
      return "blocked"
    }
  })(),
  "cookie:",
  (() => {
    try {
      document.cookie = "x=1"
      return document.cookie.includes("x=1")
    } catch (e) {
      return "blocked"
    }
  })(),
  "locks:",
  typeof navigator.locks?.request,
  "iframe:",
  window.top !== window.self,
)
```

If everything is `blocked` and you are in an iframe, the host must add `allow-same-origin` to the `sandbox` attribute — session persistence is otherwise impossible.

## Regression scenarios

- Rename of `PREFIX` → DROP old functions explicitly; stale names remain callable.
- Adding a parameter → `DROP FUNCTION name(old-arg-types)` before `CREATE`; otherwise PostgREST exposes two overloads.
- Changing a role label → scan both SQL (`'admin'` literals) and frontend (`ROLE_LABELS`, `applyRoleUI`) — they must agree.
