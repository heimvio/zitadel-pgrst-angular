import { inject } from '@angular/core';
import { Router, CanActivateFn } from '@angular/router';
import { AuthService } from './auth.service';

/**
 * Auth-Guard: nur eingeloggt. Sonst OIDC-Login starten.
 */
export const authGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  if (auth.isAuthenticated()) return true;
  auth.login();
  return false;
};

/**
 * Rollen-Guard-Fabrik (rollennamen-agnostisch, case-insensitive).
 * Server-RLS bleibt die echte Durchsetzung — das hier ist nur UX/Defense-in-Depth.
 * `fallback` = Route bei fehlender Rolle (Default '/').
 *
 * Usage: `canActivate: [authGuard, roleGuard(['staff'])]`
 */
export function roleGuard(allowed: string[], fallback = '/'): CanActivateFn {
  const allow = allowed.map(r => r.toLowerCase());
  return () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    if (auth.isAuthenticated() && auth.roles().some(r => allow.includes(r.toLowerCase()))) {
      return true;
    }
    router.navigateByUrl(fallback);
    return false;
  };
}
