import { Routes } from '@angular/router';
import { HomeComponent } from './home.component';
import { CallbackComponent } from './callback.component';

// '' shows a landing page (Login button) when logged out, the products
// example when logged in — no auto-redirect, so the app is always visible.
// `authGuard`/`roleGuard` stay available in the generic building block
// (../auth) for apps that want route-level protection.
export const routes: Routes = [
  { path: '', component: HomeComponent },
  { path: 'callback', component: CallbackComponent },
  { path: '**', redirectTo: '' }
];
