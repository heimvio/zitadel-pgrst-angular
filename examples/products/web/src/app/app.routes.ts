import { Routes } from '@angular/router';
import { authGuard, roleGuard } from '@heimvio/zitadel-pgrst-angular/auth';
import { OrgUsersListComponent } from '@heimvio/zitadel-pgrst-angular/provisioning';
import { HomeComponent } from './home.component';
import { CallbackComponent } from './callback.component';

// IAM-level routes (/admin/orgs) are intentionally NOT mounted here. Creating
// new tenant orgs is a deploy-time concern handled by bootstrap/bootstrap.sh,
// not a runtime SPA action. Only the org-scoped admin UI (/admin/users) is
// exposed to logged-in org_owners.
export const routes: Routes = [
  { path: '', component: HomeComponent },
  { path: 'callback', component: CallbackComponent },
  {
    path: 'admin/users',
    canActivate: [authGuard, roleGuard(['org_owner'])],
    component: OrgUsersListComponent
  },
  { path: '**', redirectTo: '' }
];
