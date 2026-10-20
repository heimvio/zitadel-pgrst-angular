import { ChangeDetectionStrategy, Component, input, model } from '@angular/core';

/**
 * Multi-select role picker. Catalog comes from the app via input; selection
 * is a `model()` for two-way binding. Unstyled — emits `.base-role-picker`
 * + `.base-role-option` classes for the app to style.
 */
@Component({
  selector: 'base-role-picker',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <fieldset class="base-role-picker">
      @for (role of catalog(); track role) {
        <label class="base-role-option">
          <input type="checkbox"
                 [checked]="selected().includes(role)"
                 (change)="toggle(role, $any($event.target).checked)" />
          <span>{{ role }}</span>
        </label>
      }
    </fieldset>
  `
})
export class RolePickerComponent {
  catalog = input.required<string[]>();
  selected = model<string[]>([]);

  toggle(role: string, on: boolean): void {
    const set = new Set(this.selected());
    if (on) set.add(role); else set.delete(role);
    this.selected.set(Array.from(set));
  }
}
