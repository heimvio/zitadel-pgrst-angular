import { Component, inject } from '@angular/core';
import { Router } from '@angular/router';

/**
 * OIDC-Redirect-Ziel. Der Code wird bereits im APP_INITIALIZER
 * (AuthService.init -> loadDiscoveryDocumentAndTryLogin) verarbeitet;
 * hier nur zurück auf '/'.
 */
@Component({
  selector: 'app-callback',
  standalone: true,
  template: `<p class="muted">Anmeldung wird abgeschlossen …</p>`
})
export class CallbackComponent {
  constructor() {
    inject(Router).navigateByUrl('/');
  }
}
