import { InjectionToken } from '@angular/core';

/**
 * App-supplied configuration for the provisioning building block.
 *
 * `rolesCatalog` is the set of role names this app actually uses (e.g.
 * `['tenant', 'meter_reader', 'org_owner']`). The base components render
 * pickers from this list — the DB stores roles as free strings, so there is
 * no enum to keep in sync.
 *
 * `orgAdminRole` matches the SQL `auth.org_admin_role()` default; override
 * here ONLY if the app overrode the SQL function too.
 */
export interface ProvisioningConfig {
  rolesCatalog: string[];
  orgAdminRole?: string;
  iamAdminRole?: string;
  routesBase?: string;
  /** Zitadel manager roles assigned to a newly-promoted org admin. */
  defaultZitadelManagerRoles?: string[];
}

export const PROVISIONING_CONFIG = new InjectionToken<Required<ProvisioningConfig>>('PROVISIONING_CONFIG');

export const PROVISIONING_DEFAULTS: Required<Omit<ProvisioningConfig, 'rolesCatalog'>> = {
  orgAdminRole: 'org_owner',
  iamAdminRole: 'iam_org_owner',
  routesBase: '/admin',
  defaultZitadelManagerRoles: ['ORG_OWNER']
};
