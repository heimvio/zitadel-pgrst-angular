import { EnvironmentProviders, Provider, inject, provideAppInitializer } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideOAuthClient } from 'angular-oauth2-oidc';
import { AuthService } from './auth.service';
import { authInterceptor } from './auth.interceptor';
import { loadRuntimeConfig } from './runtime-config';

/**
 * Returns the provider list for the auth building block. The app spreads it
 * into `bootstrapApplication(..., { providers: [...provideAuth(), ...] })`.
 *
 * Includes an app initializer that:
 *   1. loads `/config.json` (runtime issuer/clientId/postgrest URL),
 *   2. configures the OIDC client + finishes the code flow.
 *
 * Returned as a flat array so the inner makeEnvironmentProviders from
 * provideHttpClient/provideOAuthClient stay at the top level — nested
 * makeEnvironmentProviders has caused DI quirks in the past.
 */
export function provideAuth(): Array<Provider | EnvironmentProviders> {
  return [
    provideHttpClient(withInterceptors([authInterceptor])),
    provideOAuthClient(),
    provideAppInitializer(() => {
      // inject() MUST run synchronously before the first await — otherwise
      // the injection context is gone (NG0203). Grab the service eagerly,
      // then return the async initialization promise.
      const auth = inject(AuthService);
      return (async () => {
        await loadRuntimeConfig();
        await auth.init();
      })();
    })
  ];
}
