// auth-controller.js
// Depends on: iframe-polyfills.js, auth-storage.js, @supabase/supabase-js v2.
// Replace the CONFIG block per-project.

const CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "YOUR-ANON-KEY",
  STORAGE_KEY: "app-auth", // unique per app
  ADMIN_ROLE: "admin",
  DEFAULT_ROLE: "viewer",
  ROLE_LABELS: {
    admin: "Administrator",
    viewer: "Viewer",
  },
}

const authStorage = buildAuthStorage()
diagnoseAuthStorage(authStorage, CONFIG.STORAGE_KEY)

const supabaseClient = supabase.createClient(
  CONFIG.SUPABASE_URL,
  CONFIG.SUPABASE_ANON_KEY,
  {
    auth: {
      storage: authStorage,
      storageKey: CONFIG.STORAGE_KEY,
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: false,
      flowType: "implicit",
      // Short-circuit the Web Locks API — fixes SecurityError in sandboxed iframes
      lock: function (_name, _acquireTimeout, fn) {
        return fn()
      },
    },
  },
)

let currentUserRole = null
let appStarted = false

const els = {
  loginOverlay: document.getElementById("loginOverlay"),
  loginForm: document.getElementById("loginForm"),
  emailInput: document.getElementById("emailInput"),
  passwordInput: document.getElementById("passwordInput"),
  loginError: document.getElementById("loginError"),
  loginBtn: document.getElementById("loginBtn"),
  logoutBtn: document.getElementById("logoutBtn"),
  userAvatar: document.getElementById("userAvatar"),
  userName: document.getElementById("userName"),
  userRole: document.getElementById("userRole"),
}

function toggleLogin(loggedIn) {
  if (!els.loginOverlay) return
  els.loginOverlay.style.display = loggedIn ? "none" : "flex"
  if (!loggedIn) setTimeout(() => els.emailInput && els.emailInput.focus(), 100)
}

function showLoginError(msg) {
  if (!els.loginError) return
  els.loginError.textContent = msg || "Invalid credentials"
  els.loginError.style.display = "block"
}

function applySession(session) {
  const meta = session.user.user_metadata || {}
  const name = meta.full_name || session.user.email || "User"
  const initials = name
    .split(" ")
    .map((w) => w[0])
    .join("")
    .toUpperCase()
    .slice(0, 2)
  currentUserRole = meta.role || CONFIG.DEFAULT_ROLE
  if (els.userAvatar) els.userAvatar.textContent = initials
  if (els.userName) els.userName.textContent = name
  if (els.userRole)
    els.userRole.textContent =
      CONFIG.ROLE_LABELS[currentUserRole] || currentUserRole
  applyRoleUI()
}

function applyRoleUI() {
  const isAdmin = currentUserRole === CONFIG.ADMIN_ROLE
  document.querySelectorAll("[data-admin-only]").forEach((el) => {
    el.style.display = isAdmin ? "" : "none"
  })
}

async function handleSession(session) {
  if (!session) {
    toggleLogin(false)
    return
  }
  applySession(session)
  toggleLogin(true)
  if (!appStarted && typeof window.startApp === "function") {
    appStarted = true
    window.startApp()
  }
}

async function checkAuth() {
  const {
    data: { session },
  } = await supabaseClient.auth.getSession()
  await handleSession(session)
}

supabaseClient.auth.onAuthStateChange((event /*, session */) => {
  if (event === "SIGNED_OUT") toggleLogin(false)
})

if (els.loginForm) {
  els.loginForm.addEventListener("submit", async (e) => {
    e.preventDefault()
    els.loginError.style.display = "none"
    els.loginBtn.disabled = true
    const originalText = els.loginBtn.textContent
    els.loginBtn.textContent = "..."
    try {
      const { data, error } = await supabaseClient.auth.signInWithPassword({
        email: els.emailInput.value.trim(),
        password: els.passwordInput.value,
      })
      if (error) {
        showLoginError("Invalid email or password.")
        return
      }
      await handleSession(data.session)
    } catch (err) {
      showLoginError("Connection error. Try again.")
    } finally {
      els.loginBtn.disabled = false
      els.loginBtn.textContent = originalText
    }
  })
}

if (els.logoutBtn) {
  els.logoutBtn.addEventListener("click", async () => {
    await supabaseClient.auth.signOut()
    toggleLogin(false)
    if (els.emailInput) els.emailInput.value = ""
    if (els.passwordInput) els.passwordInput.value = ""
    appStarted = false
  })
}

// Expose for other modules
window.supabaseClient = supabaseClient
window.AUTH_CONFIG = CONFIG
window.applyRoleUI = applyRoleUI
window.getCurrentUserRole = () => currentUserRole

checkAuth()
