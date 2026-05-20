import { EnvironmentProviders, makeEnvironmentProviders } from '@angular/core';
import { Routes } from '@angular/router';
import { authGuard, roleGuard } from '@proxvex/zitadel-pgrst-auth-angular/auth';
import { PROVISIONING_CONFIG, PROVISIONING_DEFAULTS, ProvisioningConfig } from './provisioning-config';
import { OrgListComponent } from './components/org-list.component';
import { OrgUsersListComponent } from './components/org-users-list.component';

/**
 * Wires up the provisioning configuration. Routes are returned separately
 * via `provisioningRoutes()` so the app can mount them under any path tree.
 */
export function provideProvisioning(config: ProvisioningConfig): EnvironmentProviders {
  const resolved = { ...PROVISIONING_DEFAULTS, ...config };
  return makeEnvironmentProviders([
    { provide: PROVISIONING_CONFIG, useValue: resolved }
  ]);
}

/**
 * Returns the default admin routes (users + orgs). Mount via
 *   { path: 'admin', children: provisioningRoutes(config) }
 * The orgs route is gated by the IAM admin role; users by the org admin role.
 */
export function provisioningRoutes(config?: Pick<ProvisioningConfig, 'orgAdminRole' | 'iamAdminRole'>): Routes {
  const orgAdmin = config?.orgAdminRole ?? PROVISIONING_DEFAULTS.orgAdminRole;
  const iamAdmin = config?.iamAdminRole ?? PROVISIONING_DEFAULTS.iamAdminRole;
  return [
    { path: 'users', canActivate: [authGuard, roleGuard([orgAdmin])], component: OrgUsersListComponent },
    { path: 'orgs', canActivate: [authGuard, roleGuard([iamAdmin])], component: OrgListComponent }
  ];
}
