import { Inject, Injectable } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { AuthService, runtimeConfig } from '@proxvex/zitadel-pgrst-auth-angular/auth';
import { ZitadelAdminService } from './zitadel-admin.service';
import { PROVISIONING_CONFIG, ProvisioningConfig } from './provisioning-config';

export interface OrgUser {
  id: string;
  email: string | null;
  roles: string[];
  zitadel_sub: string;
  created_at: string;
}

export interface ProvisionedOrg {
  /** auth.organizations.id (DB UUID) */
  dbId: string;
  /** Zitadel organization id */
  orgId: string;
}

export interface ProvisionedUser {
  /** auth.users.id (DB UUID) */
  dbId: string;
  /** Zitadel user id (= zitadel_sub) */
  userId: string;
}

/**
 * Orchestrates the Zitadel→DB two-phase provisioning flow.
 * Idempotent on the UNIQUE bridge constraints (zitadel_org_id, zitadel_sub):
 * on retry the existing row is fetched / updated, not duplicated.
 */
@Injectable({ providedIn: 'root' })
export class ProvisioningService {
  constructor(
    private http: HttpClient,
    private auth: AuthService,
    private zitadel: ZitadelAdminService,
    @Inject(PROVISIONING_CONFIG) private cfg: Required<ProvisioningConfig>
  ) {}

  private get pgrst(): string {
    return (runtimeConfig.postgrest.url || '').replace(/\/$/, '');
  }

  private get pgrstHeaders(): HttpHeaders {
    return new HttpHeaders({
      Authorization: `Bearer ${this.auth.token ?? ''}`,
      'Content-Type': 'application/json',
      Accept: 'application/json'
    });
  }

  /**
   * IAM-level: create a Zitadel org, mirror it in auth.organizations, and
   * (optionally) promote a first human user to its org_owner.
   */
  async createOrg(name: string, firstOwner?: { email: string; givenName?: string; familyName?: string }):
    Promise<ProvisionedOrg> {
    const orgId = await this.zitadel.createOrganization(name);
    const dbId = await this.callRpc<string>('provision_org', { p_zitadel_org_id: orgId, p_name: name });

    if (firstOwner) {
      const userId = await this.zitadel.createHumanUser(orgId, {
        givenName: firstOwner.givenName ?? 'Owner',
        familyName: firstOwner.familyName ?? 'Owner',
        email: firstOwner.email
      });
      await this.zitadel.addOrgManager(orgId, userId, this.cfg.defaultZitadelManagerRoles);
      // The new owner will appear in auth.users via JIT at first login, with
      // role assignment via auth.user_roles. We can't seed roles here because
      // the caller's auth.org_id() is the IAM admin's org, not the new one.
    }

    return { dbId, orgId };
  }

  /**
   * ORG-level: invite a human user into the caller's own org with the given roles.
   */
  async createUser(p: { email: string; roles: string[]; givenName?: string; familyName?: string }): Promise<ProvisionedUser> {
    const orgId = await this.callerZitadelOrgId();
    const userId = await this.zitadel.createHumanUser(orgId, {
      givenName: p.givenName ?? p.email.split('@')[0],
      familyName: p.familyName ?? '-',
      email: p.email
    });
    const dbId = await this.callRpc<string>('provision_user', {
      p_zitadel_sub: userId, p_email: p.email, p_roles: p.roles
    });
    return { dbId, userId };
  }

  /**
   * ORG-level: create a machine user (returns client secret ONCE).
   */
  async createMachineUser(p: { userName: string; name: string; description?: string; roles: string[] }):
    Promise<ProvisionedUser & { clientId: string; clientSecret: string }> {
    const orgId = await this.callerZitadelOrgId();
    const userId = await this.zitadel.createMachineUser(orgId, {
      userName: p.userName, name: p.name, description: p.description
    });
    const { clientId, clientSecret } = await this.zitadel.createMachineSecret(orgId, userId);
    const dbId = await this.callRpc<string>('provision_user', {
      p_zitadel_sub: userId, p_email: `${p.userName}@machine.local`, p_roles: p.roles
    });
    return { dbId, userId, clientId, clientSecret };
  }

  listUsers(): Promise<OrgUser[]> {
    return this.callRpc<OrgUser[]>('list_org_users', {});
  }

  assignRole(userId: string, role: string): Promise<void> {
    return this.callRpc<void>('assign_role', { p_user_id: userId, p_role: role });
  }

  revokeRole(userId: string, role: string): Promise<void> {
    return this.callRpc<void>('revoke_role', { p_user_id: userId, p_role: role });
  }

  removeUser(userId: string): Promise<void> {
    return this.callRpc<void>('remove_user', { p_user_id: userId });
  }

  /** Zitadel org-id of the currently logged-in admin (from the JWT claim). */
  private async callerZitadelOrgId(): Promise<string> {
    const claims = this.auth.claims<Record<string, unknown>>();
    const id = (claims?.['urn:zitadel:iam:user:resourceowner:id']
             ?? claims?.['urn:zitadel:iam:org:id']) as string | undefined;
    if (!id) throw new Error('no Zitadel org claim in caller token');
    return id;
  }

  private async callRpc<T>(name: string, body: Record<string, unknown>): Promise<T> {
    return firstValueFrom(this.http.post<T>(
      `${this.pgrst}/rpc/${name}`, body, { headers: this.pgrstHeaders }));
  }
}
