import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { tokenStore } from '../tokenStore'

describe('tokenStore', () => {
  beforeEach(() => {
    window.sessionStorage.clear()
  })

  afterEach(() => {
    window.sessionStorage.clear()
  })

  it('returns nothing when nothing has been set', () => {
    expect(tokenStore.getAccessToken()).toBeNull()
    expect(tokenStore.getRefreshToken()).toBeNull()
    expect(tokenStore.isAuthenticated()).toBe(false)
  })

  it('round-trips an access+refresh pair', () => {
    tokenStore.setTokens({ accessToken: 'a', refreshToken: 'r', expiresIn: 60 })
    expect(tokenStore.getAccessToken()).toBe('a')
    expect(tokenStore.getRefreshToken()).toBe('r')
    expect(tokenStore.isAuthenticated()).toBe(true)
  })

  it('reports unauthenticated once expiry passes', () => {
    // expiresIn=1s gives us a 1s - 5s safety = expiresAt in the past.
    tokenStore.setTokens({ accessToken: 'a', expiresIn: 1 })
    // Even with the safety margin, the token is brand new but already
    // considered expired because the safety subtraction puts expiry behind us.
    expect(tokenStore.isAuthenticated()).toBe(false)
  })

  it('clear removes everything', () => {
    tokenStore.setTokens({ accessToken: 'a', refreshToken: 'r', expiresIn: 60 })
    tokenStore.clear()
    expect(tokenStore.getAccessToken()).toBeNull()
    expect(tokenStore.getRefreshToken()).toBeNull()
    expect(tokenStore.isAuthenticated()).toBe(false)
  })

  it('treats missing expiresAt as still-valid', () => {
    // setTokens with no expiresIn skips the timestamp; downstream callers
    // get isAuthenticated=true based on token presence alone. This matches
    // how a hand-injected token would behave.
    tokenStore.setTokens({ accessToken: 'a', refreshToken: 'r' })
    expect(tokenStore.isAuthenticated()).toBe(true)
  })
})
