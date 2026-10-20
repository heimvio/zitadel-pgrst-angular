import { Component, inject } from '@angular/core';
import { Router } from '@angular/router';

/**
 * OIDC redirect target. The code is already processed in the APP_INITIALIZER
 * (AuthService.init -> loadDiscoveryDocumentAndTryLogin); here we just go
 * back to '/'.
 */
@Component({
  selector: 'app-callback',
  standalone: true,
  template: `<p class="muted">Finishing sign-in …</p>`
})
export class CallbackComponent {
  constructor() {
    inject(Router).navigateByUrl('/');
  }
}
