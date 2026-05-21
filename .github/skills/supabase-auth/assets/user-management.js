// user-management.js
// Depends on: auth-controller.js (provides window.supabaseClient, AUTH_CONFIG)
// Replace {{PREFIX}} in RPC names to match your migrations.

const PREFIX = "app_" // <-- set to the same PREFIX used in SQL

const RPC = {
  LIST: PREFIX + "admin_list_users",
  UPDATE: PREFIX + "admin_update_user",
  DELETE: PREFIX + "admin_delete_user",
  CONFIRM: PREFIX + "admin_confirm_user",
}

let editingUserId = null
let deletingUserId = null

function escapeHtml(s) {
  const d = document.createElement("div")
  d.textContent = s
  return d.innerHTML
}

async function loadUsers() {
  const loading = document.getElementById("usersLoading")
  const table = document.getElementById("usersTable")
  if (loading) loading.style.display = "flex"
  if (table) table.style.display = "none"
  try {
    const { data, error } = await supabaseClient.rpc(RPC.LIST)
    if (error) throw error
    const countEl = document.getElementById("usersCount")
    if (countEl) countEl.textContent = data.length
    const tbody = document.getElementById("usersTableBody")
    tbody.innerHTML = ""
    data.forEach((u) => {
      const tr = document.createElement("tr")
      const created = new Date(u.created_at).toLocaleDateString()
      const role = u.role || AUTH_CONFIG.DEFAULT_ROLE
      const roleLbl = AUTH_CONFIG.ROLE_LABELS[role] || role
      tr.innerHTML =
        "<td>" +
        escapeHtml(u.full_name || "—") +
        "</td>" +
        "<td>" +
        escapeHtml(u.email) +
        "</td>" +
        '<td><span class="role-badge ' +
        role +
        '">' +
        roleLbl +
        "</span></td>" +
        "<td>" +
        created +
        "</td>" +
        '<td style="display:flex;gap:6px">' +
        '<button class="action-btn edit-user-btn">Edit</button>' +
        '<button class="action-btn danger delete-user-btn">Delete</button>' +
        "</td>"
      tr.querySelector(".edit-user-btn").addEventListener("click", () =>
        openEditUser(u),
      )
      tr.querySelector(".delete-user-btn").addEventListener("click", () =>
        openDeleteUser(u),
      )
      tbody.appendChild(tr)
    })
    if (loading) loading.style.display = "none"
    if (table) table.style.display = "table"
  } catch (err) {
    console.error("loadUsers error:", err)
    if (loading) loading.style.display = "none"
  }
}

function openEditUser(u) {
  editingUserId = u.user_id
  document.getElementById("userModalTitle").textContent = "Edit user"
  document.getElementById("emailField").style.display = "none"
  document.getElementById("passwordField").style.display = "none"
  document.getElementById("modalPassword").required = false
  document.getElementById("modalFullName").value = u.full_name || ""
  document.getElementById("modalRole").value =
    u.role || AUTH_CONFIG.DEFAULT_ROLE
  document.getElementById("modalError").style.display = "none"
  document.getElementById("userModal").classList.add("active")
}

function openCreateUser() {
  editingUserId = null
  document.getElementById("userModalTitle").textContent = "New user"
  document.getElementById("emailField").style.display = ""
  document.getElementById("passwordField").style.display = ""
  document.getElementById("modalPassword").required = true
  document.getElementById("userModalForm").reset()
  document.getElementById("modalError").style.display = "none"
  document.getElementById("userModal").classList.add("active")
}

function openDeleteUser(u) {
  deletingUserId = u.user_id
  document.getElementById("deleteUserName").textContent = u.full_name || u.email
  document.getElementById("deleteModalError").style.display = "none"
  document.getElementById("deleteModal").classList.add("active")
}

// Wiring
const addBtn = document.getElementById("addUserBtn")
if (addBtn) addBtn.addEventListener("click", openCreateUser)

const modalCancel = document.getElementById("modalCancelBtn")
if (modalCancel)
  modalCancel.addEventListener("click", () =>
    document.getElementById("userModal").classList.remove("active"),
  )

const form = document.getElementById("userModalForm")
if (form)
  form.addEventListener("submit", async (e) => {
    e.preventDefault()
    const saveBtn = document.getElementById("modalSaveBtn")
    const errorEl = document.getElementById("modalError")
    errorEl.style.display = "none"
    saveBtn.disabled = true
    try {
      if (editingUserId) {
        const { error } = await supabaseClient.rpc(RPC.UPDATE, {
          p_user_id: editingUserId,
          p_full_name: document.getElementById("modalFullName").value.trim(),
          p_role: document.getElementById("modalRole").value,
        })
        if (error) throw error
      } else {
        const email = document.getElementById("modalEmail").value.trim()
        const password = document.getElementById("modalPassword").value
        const fullName = document.getElementById("modalFullName").value.trim()
        const role = document.getElementById("modalRole").value

        const { data: signupData, error: signupError } =
          await supabaseClient.auth.signUp({
            email,
            password,
            options: { data: { full_name: fullName, role } },
          })
        if (signupError) throw signupError

        // Self-hosted: auto-confirm the e-mail via RPC.
        if (signupData.user) {
          const { error: confirmError } = await supabaseClient.rpc(
            RPC.CONFIRM,
            { p_user_id: signupData.user.id },
          )
          if (confirmError)
            console.warn(
              "confirm_user failed (may be unnecessary on managed Supabase):",
              confirmError,
            )
        }
      }
      document.getElementById("userModal").classList.remove("active")
      await loadUsers()
    } catch (err) {
      errorEl.textContent = err.message || "Error saving user."
      errorEl.style.display = "block"
    } finally {
      saveBtn.disabled = false
    }
  })

const delCancel = document.getElementById("deleteCancelBtn")
if (delCancel)
  delCancel.addEventListener("click", () =>
    document.getElementById("deleteModal").classList.remove("active"),
  )

const delConfirm = document.getElementById("deleteConfirmBtn")
if (delConfirm)
  delConfirm.addEventListener("click", async () => {
    const errorEl = document.getElementById("deleteModalError")
    errorEl.style.display = "none"
    delConfirm.disabled = true
    try {
      const { error } = await supabaseClient.rpc(RPC.DELETE, {
        p_user_id: deletingUserId,
      })
      if (error) throw error
      document.getElementById("deleteModal").classList.remove("active")
      await loadUsers()
    } catch (err) {
      errorEl.textContent = err.message || "Error deleting user."
      errorEl.style.display = "block"
    } finally {
      delConfirm.disabled = false
    }
  })

window.loadUsers = loadUsers
