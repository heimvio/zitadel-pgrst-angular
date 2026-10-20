import { bootstrapApplication } from '@angular/platform-browser';
import { provideRouter } from '@angular/router';
import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { provideAuth } from '@heimvio/zitadel-pgrst-angular/auth';
import { provideProvisioning } from '@heimvio/zitadel-pgrst-angular/provisioning';
import { routes } from './app/app.routes';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet],
  template: `<router-outlet></router-outlet>`
})
export class AppComponent {}

bootstrapApplication(AppComponent, {
  providers: [
    provideRouter(routes),
    ...provideAuth(),
    provideProvisioning({
      rolesCatalog: ['staff', 'customer', 'org_owner', 'iam_org_owner']
    })
  ]
}).catch(err => console.error(err));
