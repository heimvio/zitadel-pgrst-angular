import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { AuthService, runtimeConfig } from '../auth';

interface Product { name: string; price: number; }

/**
 * Mini-Beispiel auf dem generischen Auth-Baustein:
 * whoami + Produktliste der EIGENEN Org; Anlegen nur für Rolle `staff`.
 */
@Component({
  selector: 'app-products',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <h1>zitadel-pgrst-auth — Angular-Beispiel</h1>
    <p class="muted">Zitadel-Login → JWT (RS256) → PostgREST mit RLS.
      Org-Isolation via <code>auth.org_id()</code>, Rollen via
      <code>auth.user_roles</code> (App-Namen: <code>staff</code>/<code>customer</code>).</p>

    <p>
      <b>{{ auth.profile()?.org_id ? 'Org ' + auth.profile()?.org_id : '—' }}</b>
      · Rollen {{ auth.roles().length ? auth.roles().join(', ') : '(keine → Default-Deny)' }}
      <button class="sec" (click)="auth.logout()">Logout</button>
    </p>

    <h3>whoami</h3>
    <pre>{{ auth.profile() | json }}</pre>

    <h3>Produkte (nur eigene Organisation)</h3>
    <p class="muted">{{ msg() }}</p>
    <table>
      <thead><tr><th>Name</th><th>Preis</th></tr></thead>
      <tbody>
        <tr *ngFor="let p of products()"><td>{{ p.name }}</td><td>{{ p.price }}</td></tr>
      </tbody>
    </table>

    <ng-container *ngIf="auth.hasRole('staff'); else noStaff">
      <h3>Neues Produkt <span class="muted">(Rolle staff)</span></h3>
      <p>
        <input [(ngModel)]="name" placeholder="Name">
        <input [(ngModel)]="price" placeholder="9.99" size="6">
        <button (click)="add()">Anlegen</button>
        <span [class]="addClass()">{{ addMsg() }}</span>
      </p>
    </ng-container>
    <ng-template #noStaff>
      <p class="muted">Als <code>customer</code> nur Lesezugriff (Anlegen serverseitig per RLS verwehrt).</p>
    </ng-template>
  `
})
export class ProductsComponent {
  auth = inject(AuthService);
  private http = inject(HttpClient);
  private base = runtimeConfig.postgrest.url;

  products = signal<Product[]>([]);
  msg = signal('lädt …');
  name = ''; price = '';
  addMsg = signal(''); addClass = signal('muted');

  constructor() { this.reload(); }

  private reload(): void {
    this.http.get<Product[]>(`${this.base}/products?select=name,price&order=name`)
      .subscribe({
        next: r => { this.products.set(r); this.msg.set(r.length + ' Produkt(e) — ausschließlich der eigenen Org.'); },
        error: e => this.msg.set('Fehler HTTP ' + e.status)
      });
  }

  add(): void {
    this.http.post(`${this.base}/products`, { name: this.name, price: parseFloat(this.price || '0') })
      .subscribe({
        next: () => { this.addClass.set('ok'); this.addMsg.set('angelegt ✓'); this.name = this.price = ''; this.reload(); },
        error: e => { this.addClass.set('err'); this.addMsg.set('abgelehnt (HTTP ' + e.status + ') — Rolle staff nötig'); }
      });
  }
}
