import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ProvisioningService, ProvisionedOrg } from '../provisioning.service';

/**
 * IAM-level org-list with create form. Listing is intentionally omitted from
 * the base component (it would require a SECURITY-DEFINER list_orgs RPC that
 * is app-specific). Apps that want to list orgs implement their own table
 * against their domain extension (e.g. nebenkosten's hausverwaltungen).
 */
@Component({
  selector: 'base-org-list',
  standalone: true,
  imports: [FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <section class="base-org-list">
      <header><h2>Create organization</h2></header>
      <form (submit)="submit(); $event.preventDefault()">
        <label class="base-field">
          <span>Name</span>
          <input required [(ngModel)]="name" name="name" />
        </label>
        <label class="base-field">
          <span>First admin email (optional)</span>
          <input type="email" [(ngModel)]="adminEmail" name="adminEmail" />
        </label>
        @if (busy()) { <p class="base-busy">Creating…</p> }
        @if (error()) { <p class="base-error">{{ error() }}</p> }
        @if (lastCreated()) {
          <p class="base-success">Created org: {{ lastCreated()!.orgId }} (db {{ lastCreated()!.dbId }})</p>
        }
        <button type="submit" [disabled]="busy()">Create</button>
      </form>
    </section>
  `
})
export class OrgListComponent {
  private prov = inject(ProvisioningService);

  name = '';
  adminEmail = '';
  busy = signal(false);
  error = signal<string | null>(null);
  lastCreated = signal<ProvisionedOrg | null>(null);

  async submit(): Promise<void> {
    if (!this.name) return;
    this.busy.set(true);
    this.error.set(null);
    try {
      const owner = this.adminEmail ? { email: this.adminEmail } : undefined;
      const org = await this.prov.createOrg(this.name, owner);
      this.lastCreated.set(org);
      this.name = '';
      this.adminEmail = '';
    } catch (e) {
      this.error.set(e instanceof Error ? e.message : String(e));
    } finally {
      this.busy.set(false);
    }
  }
}
