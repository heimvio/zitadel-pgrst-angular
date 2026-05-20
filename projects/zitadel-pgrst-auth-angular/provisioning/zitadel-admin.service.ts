import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { AuthService, runtimeConfig } from '@proxvex/zitadel-pgrst-auth-angular/auth';

/**
 * Thin client for the Zitadel v2/v1 Management API.
 *
 * No backend / no service account: every call uses the *logged-in admin's*
 * own OIDC access token (like the Zitadel Console itself). The SPA token
 * must carry the Zitadel API audience (reserved scope
 * `urn:zitadel:iam:org:project:id:zitadel:aud`) and Zitadel CORS must allow
 * the SPA origin. Privileged instance-wide paths should be network-restricted
 * by your reverse proxy (LAN only).
 *
 * Endpoints (verified against Zitadel v4.10):
 *   - POST /v2/organizations                       -> { organizationId }
 *   - POST /v2/users/human       (x-zitadel-orgid) -> { userId }
 *   - POST /management/v1/users/machine            -> { userId }
 *   - PUT  /management/v1/users/{id}/secret        -> { clientId, clientSecret }
 *   - POST /management/v1/orgs/me/members          -> add Zitadel manager roles
 */
@Injectable({ providedIn: 'root' })
export class ZitadelAdminService {
  private http = inject(HttpClient);
  private auth = inject(AuthService);

  private get base(): string {
    return (runtimeConfig.oidc.issuer || '').replace(/\/$/, '');
  }

  private headers(orgId?: string): HttpHeaders {
    let h = new HttpHeaders({
      Authorization: `Bearer ${this.auth.token ?? ''}`,
      'Content-Type': 'application/json',
      Accept: 'application/json'
    });
    if (orgId) h = h.set('x-zitadel-orgid', orgId);
    return h;
  }

  async createOrganization(name: string): Promise<string> {
    const res = await firstValueFrom(this.http.post<{ organizationId: string }>(
      `${this.base}/v2/organizations`, { name }, { headers: this.headers() }));
    return res.organizationId;
  }

  async createHumanUser(orgId: string, p: { givenName: string; familyName: string; email: string }): Promise<string> {
    const res = await firstValueFrom(this.http.post<{ userId: string }>(
      `${this.base}/v2/users/human`,
      {
        profile: { givenName: p.givenName, familyName: p.familyName },
        email: { email: p.email, isVerified: false, sendCode: {} }
      },
      { headers: this.headers(orgId) }));
    return res.userId;
  }

  async createMachineUser(orgId: string, p: { userName: string; name: string; description?: string }): Promise<string> {
    const res = await firstValueFrom(this.http.post<{ userId: string }>(
      `${this.base}/management/v1/users/machine`,
      { userName: p.userName, name: p.name, description: p.description ?? '' },
      { headers: this.headers(orgId) }));
    return res.userId;
  }

  async createMachineSecret(orgId: string, userId: string): Promise<{ clientId: string; clientSecret: string }> {
    return firstValueFrom(this.http.put<{ clientId: string; clientSecret: string }>(
      `${this.base}/management/v1/users/${userId}/secret`, {},
      { headers: this.headers(orgId) }));
  }

  async addOrgManager(orgId: string, userId: string, roles: string[]): Promise<void> {
    await firstValueFrom(this.http.post(
      `${this.base}/management/v1/orgs/me/members`,
      { userId, roles },
      { headers: this.headers(orgId) }));
  }
}
