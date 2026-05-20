import { Routes } from '@angular/router';
import { provisioningRoutes } from '@proxvex/zitadel-pgrst-auth-angular/provisioning';
import { HomeComponent } from './home.component';
import { CallbackComponent } from './callback.component';

/**
 * '' shows a landing page (Login button) when logged out, the products
 * example when logged in. /admin/* uses the base provisioning routes —
 * /admin/users for org admins, /admin/orgs for IAM admins (both gated by
 * roleGuard from the base library).
 */
export const routes: Routes = [
  { path: '', component: HomeComponent },
  { path: 'callback', component: CallbackComponent },
  { path: 'admin', children: provisioningRoutes() },
  { path: '**', redirectTo: '' }
];
