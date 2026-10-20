import { Injectable } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { AuthService, runtimeConfig } from '@heimvio/zitadel-pgrst-angular/auth';

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
 *   - POST /management/v1/users/{id}/pats          -> { tokenId, token }
 *   - POST /management/v1/users/{id}/pats/_search  -> { result: MachinePat[] }
 *   - DELETE /management/v1/users/{id}/pats/{tokenId}
 *   - POST /management/v1/orgs/me/members          -> add Zitadel manager roles
 */

export interface MachinePat {
  /** tokenId (the PAT's identifier in Zitadel; the bearer value itself is only returned at creation) */
  id: string;
  /** RFC3339; absent if the PAT was created without an expiry */
  expirationDate?: string;
  scopes?: string[];
  /** RFC3339 creation timestamp from Zitadel's ObjectDetails */
  creationDate?: string;
}
@Injectable({ providedIn: 'root' })
export class ZitadelAdminService {
  constructor(private http: HttpClient, private auth: AuthService) {}

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

  async createHumanUser(orgId: string, p: {
    givenName: string; familyName: string; email: string;
    /** BCP47 (e.g. 'de', 'en'). Steuert die Zitadel-Notification-Mail-Sprache —
     *  Zitadel waehlt das passende message_text-Template pro Language; fehlt
     *  preferredLanguage, faellt es auf die Instance-Default-Sprache zurueck. */
    language?: string;
  }): Promise<string> {
    // verification is a Zitadel oneof — set EITHER sendCode (invite mail) OR
    // isVerified. We pick sendCode so the new user gets an email invite and
    // sets their own password.
    const profile: Record<string, unknown> = {
      givenName: p.givenName,
      familyName: p.familyName
    };
    if (p.language) profile['preferredLanguage'] = p.language;
    const res = await firstValueFrom(this.http.post<{ userId: string }>(
      `${this.base}/v2/users/human`,
      { profile, email: { email: p.email, sendCode: {} } },
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

  /**
   * Create a Personal Access Token for a machine user. The bearer `token`
   * is returned ONCE — callers must surface a copy action / warning.
   * `expirationDate` is RFC3339; omit for the Zitadel default (no expiry).
   */
  async createMachinePat(
    orgId: string,
    userId: string,
    expirationDate?: string
  ): Promise<{ tokenId: string; token: string }> {
    const body = expirationDate ? { expirationDate } : {};
    return firstValueFrom(this.http.post<{ tokenId: string; token: string }>(
      `${this.base}/management/v1/users/${userId}/pats`, body,
      { headers: this.headers(orgId) }));
  }

  /**
   * List a machine user's PATs. The bearer values are NOT returned — only
   * metadata (id, expirationDate, scopes, creationDate) is available after
   * creation.
   */
  async listMachinePats(orgId: string, userId: string): Promise<MachinePat[]> {
    const res = await firstValueFrom(this.http.post<{ result?: Array<Record<string, unknown>> }>(
      `${this.base}/management/v1/users/${userId}/pats/_search`, {},
      { headers: this.headers(orgId) }));
    return (res.result ?? []).map(r => ({
      id: String(r['id'] ?? ''),
      expirationDate: r['expirationDate'] as string | undefined,
      scopes: r['scopes'] as string[] | undefined,
      creationDate: (r['details'] as { creationDate?: string } | undefined)?.creationDate
    }));
  }

  /** Revoke a single PAT. */
  async deleteMachinePat(orgId: string, userId: string, tokenId: string): Promise<void> {
    await firstValueFrom(this.http.delete(
      `${this.base}/management/v1/users/${userId}/pats/${tokenId}`,
      { headers: this.headers(orgId) }));
  }

  async addOrgManager(orgId: string, userId: string, roles: string[]): Promise<void> {
    await firstValueFrom(this.http.post(
      `${this.base}/management/v1/orgs/me/members`,
      { userId, roles },
      { headers: this.headers(orgId) }));
  }
}
