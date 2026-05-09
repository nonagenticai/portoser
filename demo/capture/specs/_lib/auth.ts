import type { Page } from '@playwright/test';

const API_URL = process.env.PORTOSER_API_URL ?? 'http://localhost:8988';

interface LoginResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
}

async function fetchTokens(username: string, password: string): Promise<LoginResponse> {
  const res = await fetch(`${API_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });
  if (!res.ok) {
    throw new Error(`auth/login failed: ${res.status} ${await res.text()}`);
  }
  return (await res.json()) as LoginResponse;
}

/**
 * Inject Keycloak tokens into the page's sessionStorage so the SPA boots
 * past the login wall. Must be called BEFORE the first navigation that
 * loads the app shell.
 */
export async function bakeAuth(
  page: Page,
  username = 'admin',
  password = 'admin',
): Promise<void> {
  const tokens = await fetchTokens(username, password);
  const expiresAt = Date.now() + tokens.expires_in * 1000;

  await page.addInitScript(
    ({ access, refresh, expiresAt }) => {
      try {
        sessionStorage.setItem('portoser.access_token', access);
        sessionStorage.setItem('portoser.refresh_token', refresh);
        sessionStorage.setItem('portoser.access_expires_at', String(expiresAt));
      } catch {
        /* ignore — Storage isn't writable in some test environments */
      }
    },
    {
      access: tokens.access_token,
      refresh: tokens.refresh_token,
      expiresAt,
    },
  );
}
