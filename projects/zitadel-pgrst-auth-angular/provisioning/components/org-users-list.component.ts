import { ChangeDetectionStrategy, Component, inject, OnInit, signal } from '@angular/core';
import { ProvisioningService, OrgUser } from '../provisioning.service';
import { PROVISIONING_CONFIG } from '../provisioning-config';
import { AddUserDialogComponent } from './add-user-dialog.component';
import { RolePickerComponent } from './role-picker.component';

/**
 * Lists users of the caller's org, lets the org admin add new users,
 * change roles inline, and remove users.
 */
@Component({
  selector: 'base-org-users-list',
  standalone: true,
  imports: [AddUserDialogComponent, RolePickerComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <section class="base-org-users-list">
      <header class="base-org-users-header">
        <h2>Users</h2>
        <button type="button" (click)="showAdd.set(!showAdd())">
          {{ showAdd() ? 'Close' : 'Add user' }}
        </button>
      </header>

      @if (showAdd()) {
        <base-add-user-dialog (saved)="onSaved()" (cancel)="showAdd.set(false)" />
      }

      @if (loading()) { <p class="base-busy">Loading…</p> }
      @if (error()) { <p class="base-error">{{ error() }}</p> }

      <table class="base-org-users-table">
        <thead>
          <tr><th>Email</th><th>Roles</th><th></th></tr>
        </thead>
        <tbody>
          @for (u of users(); track u.id) {
            <tr>
              <td>{{ u.email }}</td>
              <td>
                <base-role-picker [catalog]="catalog"
                                  [selected]="u.roles"
                                  (selectedChange)="syncRoles(u, $event)" />
              </td>
              <td>
                <button type="button" (click)="remove(u)">Remove</button>
              </td>
            </tr>
          }
        </tbody>
      </table>
    </section>
  `
})
export class OrgUsersListComponent implements OnInit {
  private prov = inject(ProvisioningService);
  private cfg = inject(PROVISIONING_CONFIG);

  users = signal<OrgUser[]>([]);
  loading = signal(false);
  error = signal<string | null>(null);
  showAdd = signal(false);

  catalog: string[] = [];

  async ngOnInit(): Promise<void> {
    this.catalog = this.cfg.rolesCatalog;
    await this.reload();
  }

  private async reload(): Promise<void> {
    this.loading.set(true);
    this.error.set(null);
    try { this.users.set(await this.prov.listUsers()); }
    catch (e) { this.error.set(e instanceof Error ? e.message : String(e)); }
    finally { this.loading.set(false); }
  }

  async onSaved(): Promise<void> {
    this.showAdd.set(false);
    await this.reload();
  }

  async syncRoles(u: OrgUser, next: string[]): Promise<void> {
    const have = new Set(u.roles);
    const want = new Set(next);
    try {
      for (const r of want) if (!have.has(r)) await this.prov.assignRole(u.id, r);
      for (const r of have) if (!want.has(r)) await this.prov.revokeRole(u.id, r);
      await this.reload();
    } catch (e) {
      this.error.set(e instanceof Error ? e.message : String(e));
    }
  }

  async remove(u: OrgUser): Promise<void> {
    if (!confirm(`Remove user ${u.email}?`)) return;
    try { await this.prov.removeUser(u.id); await this.reload(); }
    catch (e) { this.error.set(e instanceof Error ? e.message : String(e)); }
  }
}
