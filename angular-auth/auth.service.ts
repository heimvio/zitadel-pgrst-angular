import { Injectable, signal, inject } from '@angular/core';
import { OAuthService, AuthConfig } from 'angular-oauth2-oidc';
import { runtimeConfig } from './runtime-config';

/**
 * Generischer Auth-Service (wiederverwendbar, rollennamen-agnostisch).
 *
 * Zitadel-OIDC (Authorization Code + PKCE) via angular-oauth2-oidc — dieselbe
 * Lib/Muster wie nebenkosten. Identität/Rollen kommen NICHT aus Custom-Claims,
 * sondern nach Login per `POST /rpc/ensure_principal` (JIT) + `GET /rpc/whoami`
 * aus der DB. Die App fragt nur `hasRole('<ihr-name>')`.
 */
export interface Profile {
  user_id: string | null;
  org_id: string | null;
  roles: string[];
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private oauth = inject(OAuthService);

  readonly profile = signal<Profile | null>(null);
  readonly ready = signal<boolean>(false);

  /** Vom APP_INITIALIZER aufgerufen: OIDC konfigurieren + Code-Flow abschließen. */
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
    } catch { /* nicht eingeloggt */ }
    this.ready.set(true);
  }

  login(): void { this.oauth.initCodeFlow(); }
  logout(): void { this.profile.set(null); this.oauth.logOut(); }

  get token(): string | null { return this.oauth.getAccessToken() || null; }
  isAuthenticated(): boolean { return this.oauth.hasValidAccessToken(); }
  refresh() { return this.oauth.refreshToken(); }

  roles(): string[] { return this.profile()?.roles ?? []; }
  hasRole(r: string): boolean {
    return this.roles().map(x => x.toLowerCase()).includes(r.toLowerCase());
  }

  /** JIT-Spiegel (POST = schreibbar) + Profil aus whoami laden. */
  async loadProfile(): Promise<void> {
    const base = runtimeConfig.postgrest.url;
    const h = { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json' };
    await fetch(`${base}/rpc/ensure_principal`, { method: 'POST', headers: h });
    const res = await fetch(`${base}/rpc/whoami`, { headers: h });
    this.profile.set(res.ok ? await res.json() as Profile : null);
  }
}
