import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { AuthService, runtimeConfig } from '../auth';

interface Product { name: string; price: number; }

/**
 * Mini example built on the generic auth building block:
 * whoami + product list of the OWN org; creating is staff-only.
 */
@Component({
  selector: 'app-products',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <h1>zitadel-pgrst-auth — Angular example</h1>
    <p class="muted">Zitadel login → JWT (RS256) → PostgREST with RLS.
      Org isolation via <code>auth.org_id()</code>, roles via
      <code>auth.user_roles</code> (app names: <code>staff</code>/<code>customer</code>).</p>

    <p>
      <b>{{ auth.profile()?.org_id ? 'Org ' + auth.profile()?.org_id : '—' }}</b>
      · roles {{ auth.roles().length ? auth.roles().join(', ') : '(none → default-deny)' }}
      <button class="sec" (click)="auth.logout()">Logout</button>
    </p>

    <h3>whoami</h3>
    <pre>{{ auth.profile() | json }}</pre>

    <h3>Products (own organization only)</h3>
    <p class="muted">{{ msg() }}</p>
    <table>
      <thead><tr><th>Name</th><th>Price</th></tr></thead>
      <tbody>
        <tr *ngFor="let p of products()"><td>{{ p.name }}</td><td>{{ p.price }}</td></tr>
      </tbody>
    </table>

    <ng-container *ngIf="auth.hasRole('staff'); else noStaff">
      <h3>New product <span class="muted">(role staff)</span></h3>
      <p>
        <input [(ngModel)]="name" placeholder="Name">
        <input [(ngModel)]="price" placeholder="9.99" size="6">
        <button (click)="add()">Create</button>
        <span [class]="addClass()">{{ addMsg() }}</span>
      </p>
    </ng-container>
    <ng-template #noStaff>
      <p class="muted">As <code>customer</code> read-only access (creating is denied server-side by RLS).</p>
    </ng-template>
  `
})
export class ProductsComponent {
  auth = inject(AuthService);
  private http = inject(HttpClient);
  private base = runtimeConfig.postgrest.url;

  products = signal<Product[]>([]);
  msg = signal('loading …');
  name = ''; price = '';
  addMsg = signal(''); addClass = signal('muted');

  constructor() { this.reload(); }

  private reload(): void {
    this.http.get<Product[]>(`${this.base}/products?select=name,price&order=name`)
      .subscribe({
        next: r => { this.products.set(r); this.msg.set(r.length + ' product(s) — own org only.'); },
        error: e => this.msg.set('Error HTTP ' + e.status)
      });
  }

  add(): void {
    this.http.post(`${this.base}/products`, { name: this.name, price: parseFloat(this.price || '0') })
      .subscribe({
        next: () => { this.addClass.set('ok'); this.addMsg.set('created ✓'); this.name = this.price = ''; this.reload(); },
        error: e => { this.addClass.set('err'); this.addMsg.set('denied (HTTP ' + e.status + ') — role staff required'); }
      });
  }
}
