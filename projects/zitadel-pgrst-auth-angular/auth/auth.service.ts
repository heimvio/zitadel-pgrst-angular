import { Injectable, signal } from '@angular/core';
import { OAuthService, AuthConfig } from 'angular-oauth2-oidc';
import { runtimeConfig } from './runtime-config';

/**
 * Generic auth service (reusable, role-name-agnostic).
 *
 * Zitadel OIDC (Authorization Code + PKCE) via angular-oauth2-oidc — the same
 * library/pattern as nebenkosten. Identity/roles do NOT come from custom
 * claims, but after login via `POST /rpc/ensure_principal` (JIT) +
 * `GET /rpc/whoami` from the DB. The app only asks `hasRole('<its-name>')`.
 */
export interface Profile {
  user_id: string | null;
  org_id: string | null;
  roles: string[];
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  readonly profile = signal<Profile | null>(null);
  readonly ready = signal<boolean>(false);

  constructor(private oauth: OAuthService) {}

  /** Called by the APP_INITIALIZER: configure OIDC + finish the code flow. */
  async init(): Promise<void> {
    const cfg: AuthConfig = {
      issuer: runtimeConfig.oidc.issuer,
      clientId: runtimeConfig.oidc.clientId,
      redirectUri: window.location.origin + runtimeConfig.oidc.redirectPath,
      responseType: 'code',
      scope: runtimeConfig.oidc.scope,
      requireHttps: false,
      showDebugInformation: false,
      strictDiscoveryDocumentValidation: false
    };
    this.oauth.configure(cfg);
    try {
      await this.oauth.loadDiscoveryDocumentAndTryLogin();
      if (this.oauth.hasValidAccessToken()) await this.loadProfile();
    } catch { /* not logged in */ }
    this.ready.set(true);
  }

  login(): void { this.oauth.initCodeFlow(); }
  logout(): void { this.profile.set(null); this.oauth.logOut(); }

  get token(): string | null { return this.oauth.getAccessToken() || null; }
  isAuthenticated(): boolean { return this.oauth.hasValidAccessToken(); }
  refresh() { return this.oauth.refreshToken(); }

  /** Identity claims from the current ID token (null if not logged in). */
  claims<T = Record<string, unknown>>(): T | null {
    return (this.oauth.getIdentityClaims() as T | null) ?? null;
  }

  roles(): string[] { return this.profile()?.roles ?? []; }
  hasRole(r: string): boolean {
    return this.roles().map(x => x.toLowerCase()).includes(r.toLowerCase());
  }

  /** JIT mirror (POST = writable) + load profile from whoami. */
  async loadProfile(): Promise<void> {
    const base = runtimeConfig.postgrest.url;
    const h = { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json' };
    await fetch(`${base}/rpc/ensure_principal`, { method: 'POST', headers: h });
    const res = await fetch(`${base}/rpc/whoami`, { headers: h });
    this.profile.set(res.ok ? await res.json() as Profile : null);
  }
}
