import { EnvironmentProviders, APP_INITIALIZER, inject, makeEnvironmentProviders } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideOAuthClient } from 'angular-oauth2-oidc';
import { AuthService } from './auth.service';
import { authInterceptor } from './auth.interceptor';
import { loadRuntimeConfig } from './runtime-config';

/**
 * Wires up HTTP client with the PostgREST bearer interceptor, the OIDC client,
 * and an APP_INITIALIZER that loads `/config.json` and finishes the OIDC code flow.
 */
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
