/**
 * Direct fetch() calls for the auth endpoints.
 *
 * We deliberately *don't* go through the shared axios client here, because
 * its 401 interceptor would try to refresh-and-retry — and the refresh call
 * itself can return 401, which would loop. Auth flows talk to the backend
 * with raw fetch and surface failures cleanly.
 */

const jsonHeaders = { 'Content-Type': 'application/json', Accept: 'application/json' }

async function postJSON(path, body) {
  const resp = await fetch(path, {
    method: 'POST',
    headers: jsonHeaders,
    body: JSON.stringify(body),
  })
  if (!resp.ok) {
    let detail
    try {
      detail = (await resp.json()).detail
    } catch {
      detail = resp.statusText
    }
    const err = new Error(detail || `HTTP ${resp.status}`)
    err.status = resp.status
    throw err
  }
  return resp.json()
}

export async function getPublicConfig() {
  // GET /api/config is public per backend PUBLIC_ENDPOINTS.
  const resp = await fetch('/api/config', { headers: { Accept: 'application/json' } })
  if (!resp.ok) {
    throw new Error(`Failed to read public config: HTTP ${resp.status}`)
  }
  return resp.json()
}

export async function login(username, password) {
  return postJSON('/api/auth/login', { username, password })
}

export async function refresh(refreshToken) {
  return postJSON('/api/auth/refresh', { refresh_token: refreshToken })
}

export async function logout(refreshToken) {
  // Best-effort: server may already have rotated the token. Either way we
  // clear the local store after this resolves.
  try {
    await postJSON('/api/auth/logout', { refresh_token: refreshToken })
  } catch {
    // Swallow — logout must always complete client-side.
  }
}
