import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AuthService } from '../auth';
import { ProductsComponent } from './products.component';

/**
 * Landing page. Not logged in -> title + Login button + demo users.
 * Logged in -> the products example. No auto-redirect, so the app is
 * always visible (the OIDC redirect happens only on the Login click).
 */
@Component({
  selector: 'app-home',
  standalone: true,
  imports: [CommonModule, ProductsComponent],
  template: `
    <ng-container *ngIf="auth.ready(); else loading">
      <ng-container *ngIf="auth.isAuthenticated(); else landing">
        <app-products></app-products>
      </ng-container>
    </ng-container>

    <ng-template #loading><p class="muted">Loading …</p></ng-template>

    <ng-template #landing>
      <h1>zitadel-pgrst-auth — Angular example</h1>
      <p class="muted">Zitadel login → JWT (RS256) → PostgREST with RLS.
        Tenant isolation via <code>auth.org_id()</code>, roles via
        <code>auth.user_roles</code> (app names <code>staff</code>/<code>customer</code>).</p>
      <p><button (click)="auth.login()">Login</button></p>
      <ng-container *ngIf="demo() as d">
        <p class="muted">Demo users (password <code>{{ d.password }}</code>):</p>
        <ul class="muted">
          <li *ngFor="let u of d.users">{{ u }}</li>
        </ul>
      </ng-container>
    </ng-template>
  `
})
export class HomeComponent {
  auth = inject(AuthService);
  demo = signal<{ password: string; users: string[] } | null>(null);

  constructor() {
    fetch('config.json', { cache: 'no-store' })
      .then(r => r.ok ? r.json() : null)
      .then(c => { if (c?.demo) this.demo.set(c.demo); })
      .catch(() => {});
  }
}
