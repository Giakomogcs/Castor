// auth-storage.js
// Builds a Storage adapter for Supabase:
//   1) real localStorage
//   2) cookies (chunked for long JWTs)
//   3) in-memory (session lost on reload — logs a warning)
//
// Also prints a boot diagnostic to help debug "session lost in iframe".

function buildAuthStorage() {
  // 1) localStorage
  try {
    var k = "__ls_probe__"
    localStorage.setItem(k, "1")
    if (localStorage.getItem(k) === "1") {
      localStorage.removeItem(k)
      return {
        getItem: function (key) {
          try {
            return localStorage.getItem(key)
          } catch (e) {
            return null
          }
        },
        setItem: function (key, val) {
          try {
            localStorage.setItem(key, val)
          } catch (e) {}
        },
        removeItem: function (key) {
          try {
            localStorage.removeItem(key)
          } catch (e) {}
        },
      }
    }
  } catch (e) {}

  // 2) cookies
  function setCookie(name, val, days) {
    var d = new Date()
    d.setTime(d.getTime() + days * 864e5)
    document.cookie =
      name +
      "=" +
      encodeURIComponent(val) +
      "; expires=" +
      d.toUTCString() +
      "; path=/; SameSite=Lax"
  }
  function getCookie(name) {
    var m = document.cookie.match(
      new RegExp(
        "(?:^|; )" +
          name.replace(/([.$?*|{}()\[\]\\/+^])/g, "\\$1") +
          "=([^;]*)",
      ),
    )
    return m ? decodeURIComponent(m[1]) : null
  }
  function delCookie(name) {
    document.cookie = name + "=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/"
  }
  try {
    var ck = "__ck_probe__"
    setCookie(ck, "1", 1)
    if (getCookie(ck) === "1") {
      delCookie(ck)
      var CHUNK = 3500
      return {
        getItem: function (key) {
          var meta = getCookie(key + "__n")
          if (!meta) return getCookie(key)
          var n = parseInt(meta, 10),
            out = ""
          for (var i = 0; i < n; i++) {
            var part = getCookie(key + "__" + i)
            if (part == null) return null
            out += part
          }
          return out
        },
        setItem: function (key, val) {
          if (val.length <= CHUNK) {
            setCookie(key, val, 7)
            delCookie(key + "__n")
            return
          }
          var n = Math.ceil(val.length / CHUNK)
          setCookie(key + "__n", String(n), 7)
          for (var i = 0; i < n; i++)
            setCookie(key + "__" + i, val.slice(i * CHUNK, (i + 1) * CHUNK), 7)
          delCookie(key)
        },
        removeItem: function (key) {
          delCookie(key)
          var meta = getCookie(key + "__n")
          if (meta) {
            var n = parseInt(meta, 10)
            for (var i = 0; i < n; i++) delCookie(key + "__" + i)
            delCookie(key + "__n")
          }
        },
      }
    }
  } catch (e) {}

  // 3) in-memory
  console.warn(
    "[auth] No persistent storage available; session will be lost on reload.",
  )
  var mem = {}
  return {
    getItem: function (k) {
      return k in mem ? mem[k] : null
    },
    setItem: function (k, v) {
      mem[k] = String(v)
    },
    removeItem: function (k) {
      delete mem[k]
    },
  }
}

function diagnoseAuthStorage(storage, storageKey) {
  var safe = function (fn, fb) {
    try {
      return fn()
    } catch (e) {
      return fb
    }
  }
  var raw = safe(function () {
    return storage.getItem(storageKey)
  }, null)
  var lsKeys = safe(function () {
    return Object.keys(localStorage)
  }, "blocked")
  var cookiesLen = safe(function () {
    return (document.cookie || "").length
  }, "blocked (sandboxed)")
  var inIframe = window.top !== window.self
  var sandboxed = cookiesLen === "blocked (sandboxed)"
  console.log(
    "[auth] Boot diag:",
    "\n  location:",
    location.href,
    "\n  origin:",
    location.origin,
    "\n  in iframe:",
    inIframe,
    "\n  sandboxed:",
    sandboxed,
    "\n  stored session present:",
    !!raw,
    "\n  stored size:",
    raw ? raw.length : 0,
    "\n  localStorage keys:",
    lsKeys,
    "\n  cookies length:",
    cookiesLen,
  )
  if (sandboxed) {
    console.warn(
      "[auth] Sandboxed iframe without allow-same-origin — session persistence is impossible.",
    )
  }
}

// Expose for non-module usage
window.buildAuthStorage = buildAuthStorage
window.diagnoseAuthStorage = diagnoseAuthStorage
