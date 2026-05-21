# Frontend Reference

The sample assets are framework-agnostic vanilla JS. Adapt to React/Vue/Svelte by moving logic into hooks/composables; the Supabase calls are identical.

## Required DOM IDs (sample UI)

| ID                                                                                                                                                      | Purpose               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `loginOverlay`                                                                                                                                          | Fullscreen login gate |
| `loginForm`, `emailInput`, `passwordInput`, `loginBtn`, `loginError`                                                                                    | Login form            |
| `logoutBtn`                                                                                                                                             | Sign out              |
| `userAvatar`, `userName`, `userRole`                                                                                                                    | Signed-in user chip   |
| `usersSection`, `usersTable`, `usersTableBody`, `usersCount`, `usersLoading`                                                                            | User management view  |
| `addUserBtn`, `userModal`, `userModalForm`, `modalEmail`, `modalPassword`, `modalFullName`, `modalRole`, `modalError`, `modalCancelBtn`, `modalSaveBtn` | Create/edit modal     |
| `deleteModal`, `deleteUserName`, `deleteModalError`, `deleteCancelBtn`, `deleteConfirmBtn`                                                              | Delete modal          |
| Elements hidden for non-admins: anything with `data-admin-only` attribute                                                                               |

## Load order (HTML)

```html
<!-- 1. Iframe polyfills FIRST (before SDK reads localStorage on import) -->
<script src="./auth/iframe-polyfills.js"></script>
<!-- 2. Supabase SDK -->
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<!-- 3. Auth controller (creates the client) -->
<script src="./auth/auth-controller.js"></script>
<!-- 4. User management (depends on client) -->
<script src="./auth/user-management.js"></script>
```

## Lifecycle

```
boot
 └─ buildAuthStorage()         // localStorage → cookies → memory
 └─ createClient({ storage })
 └─ checkAuth()                // getSession()
     ├─ no session → show login overlay
     └─ has session → applySession(user) → applyRoleUI() → startApp()

login submit → signInWithPassword → handleSession(session)
logout click → signOut → show login overlay
onAuthStateChange('SIGNED_OUT') → show login overlay
```

## Role-based UI

`applyRoleUI()` reads `session.user.user_metadata.role`, then toggles:

- every element with `data-admin-only` → `display: none` when not admin
- the "Users" nav item, the "New user" button, any write action

Always pair with the SQL admin guard. UI hiding is UX, not security.

## Session persistence in iframes

Supabase v2 creates a client that by default uses `localStorage` and `navigator.locks`. Both may be blocked.

Solution:

1. Polyfill `navigator.locks` at boot (required — Supabase imports it synchronously).
2. Provide a custom `storage` adapter with fallbacks.
3. Override the internal lock with `lock: (_n, _t, fn) => fn()` to short-circuit the Web Locks API call path even when the polyfill is in place.

All three are pre-wired in [../assets/auth-controller.js](../assets/auth-controller.js).

## Boot diagnostic

`auth-storage.js` prints a one-shot console block on boot: origin, iframe status, sandbox detection, stored-session presence, localStorage keys, cookie length. Ask the user to paste this block when debugging "session lost".

## Error messages

Localize via a small `MSG` map, e.g. for `pt-BR`:

```js
const MSG = {
  invalidCreds: "E-mail ou senha incorretos.",
  networkErr: "Erro ao conectar. Tente novamente.",
  accessDenied: "Acesso negado: apenas administradores.",
}
```

Never surface `error.message` raw from Supabase to end users (it can leak whether an email exists).
