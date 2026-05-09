/**
 * Token storage for the SPA's Keycloak access/refresh tokens.
 *
 * We use sessionStorage rather than localStorage so a closed tab forces
 * re-authentication; that lowers the blast radius if a token leaks via XSS
 * (still bad — sessionStorage is JS-readable — but persistence makes it
 * worse).
 *
 * All consumers MUST go through this module rather than touching
 * sessionStorage directly, so a future move to in-memory or HttpOnly cookies
 * stays a single-file change.
 */

const ACCESS_KEY = 'portoser.access_token'
const REFRESH_KEY = 'portoser.refresh_token'
const EXPIRES_AT_KEY = 'portoser.access_expires_at'

const memorySafe = () => typeof window !== 'undefined' && !!window.sessionStorage

export const tokenStore = {
  getAccessToken() {
    if (!memorySafe()) return null
    return window.sessionStorage.getItem(ACCESS_KEY)
  },

  getRefreshToken() {
    if (!memorySafe()) return null
    return window.sessionStorage.getItem(REFRESH_KEY)
  },

  /** True if we have an access token and it hasn't expired. */
  isAuthenticated() {
    if (!memorySafe()) return false
    const token = window.sessionStorage.getItem(ACCESS_KEY)
    if (!token) return false
    const expiresAtStr = window.sessionStorage.getItem(EXPIRES_AT_KEY)
    if (!expiresAtStr) return true  // best-effort: token present, no expiry recorded
    return Date.now() < Number(expiresAtStr)
  },

  /**
   * Persist a token bundle from /api/auth/login or /api/auth/refresh.
   * `expiresIn` is seconds; we store the absolute deadline so a navigation
   * doesn't drift the expiry clock.
   */
  setTokens({ accessToken, refreshToken, expiresIn }) {
    if (!memorySafe()) return
    window.sessionStorage.setItem(ACCESS_KEY, accessToken)
    if (refreshToken) {
      window.sessionStorage.setItem(REFRESH_KEY, refreshToken)
    }
    if (expiresIn) {
      const expiresAt = Date.now() + (Number(expiresIn) * 1000) - 5000  // 5s safety margin
      window.sessionStorage.setItem(EXPIRES_AT_KEY, String(expiresAt))
    }
  },

  clear() {
    if (!memorySafe()) return
    window.sessionStorage.removeItem(ACCESS_KEY)
    window.sessionStorage.removeItem(REFRESH_KEY)
    window.sessionStorage.removeItem(EXPIRES_AT_KEY)
  },
}
