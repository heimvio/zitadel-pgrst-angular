import { ChangeDetectionStrategy, Component, inject, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ProvisioningService, ProvisionedUser } from '../provisioning.service';
import { PROVISIONING_CONFIG } from '../provisioning-config';
import { RolePickerComponent } from './role-picker.component';

/**
 * Inline form (not a modal — apps wrap it if they need a dialog).
 * Emits `saved` after a successful provision; `cancel` for app-driven close.
 */
@Component({
  selector: 'base-add-user-dialog',
  standalone: true,
  imports: [FormsModule, RolePickerComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <form class="base-add-user-dialog" (submit)="submit(); $event.preventDefault()">
      <label class="base-field">
        <span>Email</span>
        <input type="email" required [(ngModel)]="email" name="email" />
      </label>
      <label class="base-field">
        <span>Given name</span>
        <input [(ngModel)]="givenName" name="givenName" />
      </label>
      <label class="base-field">
        <span>Family name</span>
        <input [(ngModel)]="familyName" name="familyName" />
      </label>
      @if (!fixedRoles()) {
        <base-role-picker [catalog]="catalog()" [(selected)]="roles" />
      }
      @if (busy()) { <p class="base-busy">Provisioning…</p> }
      @if (error()) { <p class="base-error">{{ error() }}</p> }
      <div class="base-actions">
        <button type="submit" [disabled]="busy()">Create user</button>
        <button type="button" (click)="cancel.emit()">Cancel</button>
      </div>
    </form>
  `
})
export class AddUserDialogComponent {
  private prov = inject(ProvisioningService);
  private cfg = inject(PROVISIONING_CONFIG);

  /** Optional override; defaults to the app-wide rolesCatalog from config. */
  catalogOverride = input<string[] | null>(null, { alias: 'catalog' });
  /** If set, roles are fixed (no picker shown) — e.g. ['tenant']. */
  fixedRoles = input<string[] | null>(null);

  saved = output<ProvisionedUser>();
  cancel = output<void>();

  email = '';
  givenName = '';
  familyName = '';
  roles = signal<string[]>([]);
  busy = signal(false);
  error = signal<string | null>(null);

  catalog(): string[] {
    return this.catalogOverride() ?? this.cfg.rolesCatalog;
  }

  async submit(): Promise<void> {
    if (!this.email) return;
    this.busy.set(true);
    this.error.set(null);
    try {
      const out = await this.prov.createUser({
        email: this.email,
        roles: this.fixedRoles() ?? this.roles(),
        givenName: this.givenName || undefined,
        familyName: this.familyName || undefined
      });
      this.saved.emit(out);
      this.email = '';
      this.givenName = '';
      this.familyName = '';
      this.roles.set([]);
    } catch (e) {
      this.error.set(e instanceof Error ? e.message : String(e));
    } finally {
      this.busy.set(false);
    }
  }
}
