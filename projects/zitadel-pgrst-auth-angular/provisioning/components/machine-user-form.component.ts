import { ChangeDetectionStrategy, Component, inject, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ProvisioningService } from '../provisioning.service';
import { PROVISIONING_CONFIG } from '../provisioning-config';
import { RolePickerComponent } from './role-picker.component';

interface CreatedMachine {
  userId: string;
  clientId: string;
  clientSecret: string;
}

/**
 * Machine-user creation. The client secret is shown ONCE — apps must
 * surface a copy action / warning around the displayed value.
 */
@Component({
  selector: 'base-machine-user-form',
  standalone: true,
  imports: [FormsModule, RolePickerComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <section class="base-machine-user-form">
      <header><h2>Create machine user</h2></header>
      <form (submit)="submit(); $event.preventDefault()">
        <label class="base-field">
          <span>Username</span>
          <input required [(ngModel)]="userName" name="userName" pattern="[a-z0-9_\\-]+" />
        </label>
        <label class="base-field">
          <span>Display name</span>
          <input required [(ngModel)]="name" name="name" />
        </label>
        @if (!fixedRoles()) {
          <base-role-picker [catalog]="catalog()" [(selected)]="roles" />
        }
        @if (busy()) { <p class="base-busy">Creating…</p> }
        @if (error()) { <p class="base-error">{{ error() }}</p> }
        <button type="submit" [disabled]="busy()">Create</button>
      </form>

      @if (created(); as c) {
        <aside class="base-machine-secret">
          <h3>Client credentials — visible once</h3>
          <p><strong>User ID:</strong> {{ c.userId }}</p>
          <p><strong>Client ID:</strong> {{ c.clientId }}</p>
          <p><strong>Client secret:</strong> <code>{{ c.clientSecret }}</code></p>
          <button type="button" (click)="created.set(null)">Dismiss</button>
        </aside>
      }
    </section>
  `
})
export class MachineUserFormComponent {
  private prov = inject(ProvisioningService);
  private cfg = inject(PROVISIONING_CONFIG);

  catalogOverride = input<string[] | null>(null, { alias: 'catalog' });
  fixedRoles = input<string[] | null>(null);

  saved = output<CreatedMachine>();

  userName = '';
  name = '';
  roles = signal<string[]>([]);
  busy = signal(false);
  error = signal<string | null>(null);
  created = signal<CreatedMachine | null>(null);

  catalog(): string[] {
    return this.catalogOverride() ?? this.cfg.rolesCatalog;
  }

  async submit(): Promise<void> {
    if (!this.userName || !this.name) return;
    this.busy.set(true);
    this.error.set(null);
    try {
      const out = await this.prov.createMachineUser({
        userName: this.userName,
        name: this.name,
        roles: this.fixedRoles() ?? this.roles()
      });
      const c = { userId: out.userId, clientId: out.clientId, clientSecret: out.clientSecret };
      this.created.set(c);
      this.saved.emit(c);
      this.userName = '';
      this.name = '';
      this.roles.set([]);
    } catch (e) {
      this.error.set(e instanceof Error ? e.message : String(e));
    } finally {
      this.busy.set(false);
    }
  }
}
