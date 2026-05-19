/**
 * Generischer Angular-Auth-Baustein für „Zitadel → PostgREST mit RLS".
 * Wiederverwendbar (z. B. von nebenkosten): kopier-/pfadbar als Einheit.
 *
 * - AuthService: OIDC-PKCE (angular-oauth2-oidc), JIT (ensure_principal),
 *   whoami-Profil-Signal, rollennamen-agnostische Helfer.
 * - authInterceptor: Bearer nur an PostgREST, 401-Refresh.
 * - authGuard / roleGuard: Routenschutz.
 * - provideAuth(): APP_INITIALIZER (config.json + OIDC-Init) + Interceptor.
 */
import { EnvironmentProviders, APP_INITIALIZER, inject } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideOAuthClient } from 'angular-oauth2-oidc';
import { makeEnvironmentProviders } from '@angular/core';
import { AuthService } from './auth.service';
import { authInterceptor } from './auth.interceptor';
import { loadRuntimeConfig } from './runtime-config';

export { AuthService } from './auth.service';
export type { Profile } from './auth.service';
export { authInterceptor } from './auth.interceptor';
export { authGuard, roleGuard } from './role.guard';
export { runtimeConfig } from './runtime-config';

export function provideAuth(): EnvironmentProviders {
  return makeEnvironmentProviders([
    provideHttpClient(withInterceptors([authInterceptor])),
    provideOAuthClient(),
    {
      provide: APP_INITIALIZER,
      multi: true,
      useFactory: () => {
        const auth = inject(AuthService);
        return async () => { await loadRuntimeConfig(); await auth.init(); };
      }
    }
  ]);
}
