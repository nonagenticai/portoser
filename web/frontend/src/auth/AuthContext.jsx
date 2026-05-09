import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { tokenStore } from './tokenStore'
import * as authApi from './authApi'

/**
 * Auth state for the whole app. Wraps:
 *   - bootstrap (read /api/config to find out if auth is even on)
 *   - login / logout / token refresh
 *   - "is the user authenticated right now"
 *
 * When the backend has Keycloak disabled, every consumer sees
 *   { authEnabled: false, isAuthenticated: true }
 * so the UI gates work the same in dev (no auth) and prod (Keycloak on).
 */

const AuthContext = createContext(null)

export function AuthProvider({ children }) {
  const [config, setConfig] = useState(null)  // {auth_enabled, keycloak_url, ...} | null while loading
  const [isAuthenticated, setIsAuthenticated] = useState(tokenStore.isAuthenticated())
  const [user, setUser] = useState(null)
  const [error, setError] = useState(null)
  const refreshTimerRef = useRef(null)

  // Bootstrap: read public config to learn whether Keycloak is enabled.
  useEffect(() => {
    let cancelled = false
    authApi.getPublicConfig()
      .then((cfg) => { if (!cancelled) setConfig(cfg) })
      .catch((err) => { if (!cancelled) setError(err) })
    return () => { cancelled = true }
  }, [])

  const scheduleRefresh = useCallback((expiresIn) => {
    if (refreshTimerRef.current) {
      clearTimeout(refreshTimerRef.current)
      refreshTimerRef.current = null
    }
    if (!expiresIn) return
    // Refresh at 80% of the access-token lifetime, with a hard floor of 30s
    // so a misbehaving IdP can't pin us in a tight refresh loop.
    const delay = Math.max(30_000, Math.round(expiresIn * 1000 * 0.8))
    refreshTimerRef.current = setTimeout(() => { tryRefresh() }, delay)
  }, [])

  const tryRefresh = useCallback(async () => {
    const rt = tokenStore.getRefreshToken()
    if (!rt) {
      tokenStore.clear()
      setIsAuthenticated(false)
      return false
    }
    try {
      const res = await authApi.refresh(rt)
      tokenStore.setTokens({
        accessToken: res.access_token,
        refreshToken: res.refresh_token,
        expiresIn: res.expires_in,
      })
      setIsAuthenticated(true)
      scheduleRefresh(res.expires_in)
      return true
    } catch {
      tokenStore.clear()
      setIsAuthenticated(false)
      return false
    }
  }, [scheduleRefresh])

  const doLogin = useCallback(async (username, password) => {
    const res = await authApi.login(username, password)
    tokenStore.setTokens({
      accessToken: res.access_token,
      refreshToken: res.refresh_token,
      expiresIn: res.expires_in,
    })
    setUser(res.user || null)
    setIsAuthenticated(true)
    scheduleRefresh(res.expires_in)
    return res.user
  }, [scheduleRefresh])

  const doLogout = useCallback(async () => {
    const rt = tokenStore.getRefreshToken()
    if (rt) {
      await authApi.logout(rt)
    }
    tokenStore.clear()
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current)
    setIsAuthenticated(false)
    setUser(null)
  }, [])

  // If we landed with a token in sessionStorage, schedule the first refresh.
  useEffect(() => {
    if (isAuthenticated && tokenStore.getRefreshToken()) {
      // We don't know the original expiresIn, so refresh sooner rather than later.
      scheduleRefresh(60)
    }
    return () => {
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const value = useMemo(() => ({
    // null while we haven't fetched /api/config yet
    config,
    authEnabled: config ? config.auth_enabled : null,
    // `null` config = still loading. For the UI this means "show a splash".
    bootstrapped: config !== null || error !== null,
    bootstrapError: error,
    // When auth is disabled at the backend, every request goes through; treat
    // the user as authenticated so route gates don't hide the whole app.
    isAuthenticated: config && !config.auth_enabled ? true : isAuthenticated,
    user,
    login: doLogin,
    logout: doLogout,
    refresh: tryRefresh,
  }), [config, error, isAuthenticated, user, doLogin, doLogout, tryRefresh])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) {
    throw new Error('useAuth must be used inside <AuthProvider>')
  }
  return ctx
}
