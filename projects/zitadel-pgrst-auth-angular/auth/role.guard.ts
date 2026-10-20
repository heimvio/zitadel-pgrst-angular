import { inject } from '@angular/core';
import { Router, CanActivateFn } from '@angular/router';
import { AuthService } from './auth.service';

/**
 * Auth guard: logged in only. Otherwise start the OIDC login.
 */
export const authGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  if (auth.isAuthenticated()) return true;
  auth.login();
  return false;
};

/**
 * Role guard factory (role-name-agnostic, case-insensitive).
 * Server-side RLS remains the real enforcement — this is only UX/defense-in-depth.
 * `fallback` = route when the role is missing (default '/').
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
