// iframe-polyfills.js
// Load BEFORE the Supabase SDK.
// Polyfills localStorage, sessionStorage and navigator.locks so the SDK
// does not crash in sandboxed/partitioned iframe contexts.
// Session persistence still requires cookies or allow-same-origin;
// these polyfills only prevent *synchronous* errors at boot.

;(function () {
  function createMemoryStorage() {
    var store = {}
    return {
      getItem: function (k) {
        return store.hasOwnProperty(k) ? store[k] : null
      },
      setItem: function (k, v) {
        store[k] = String(v)
      },
      removeItem: function (k) {
        delete store[k]
      },
      clear: function () {
        for (var p in store) delete store[p]
      },
      get length() {
        return Object.keys(store).length
      },
      key: function (i) {
        return Object.keys(store)[i] || null
      },
    }
  }
  try {
    window.sessionStorage
  } catch (e) {
    Object.defineProperty(window, "sessionStorage", {
      value: createMemoryStorage(),
      writable: false,
    })
  }
  try {
    window.localStorage
  } catch (e) {
    Object.defineProperty(window, "localStorage", {
      value: createMemoryStorage(),
      writable: false,
    })
  }

  // navigator.locks — always override; Supabase v2 uses it for token refresh
  // and throws SecurityError in sandboxed contexts even when the API exists.
  var noopRequest = function (_name, _opts, cb) {
    if (typeof _opts === "function") cb = _opts
    return Promise.resolve(cb({ name: _name, mode: "exclusive" }))
  }
  try {
    Object.defineProperty(navigator, "locks", {
      value: {
        request: noopRequest,
        query: function () {
          return Promise.resolve({ held: [], pending: [] })
        },
      },
      writable: true,
      configurable: true,
    })
  } catch (e) {
    try {
      navigator.locks = {
        request: noopRequest,
        query: function () {
          return Promise.resolve({ held: [], pending: [] })
        },
      }
    } catch (e2) {}
  }
})()
