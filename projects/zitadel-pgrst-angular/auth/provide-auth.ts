import { EnvironmentProviders, Provider, inject, provideAppInitializer } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideOAuthClient } from 'angular-oauth2-oidc';
import { AuthService } from './auth.service';
import { authInterceptor } from './auth.interceptor';
import { DEFAULT_CONFIG_URL, RuntimeConfig, loadRuntimeConfig, runtimeConfig } from './runtime-config';

/** Options of `provideAuth()`. Everything is optional; `provideAuth()` keeps the old behaviour. */
export interface ProvideAuthOptions {
  /**
   * Where to load the runtime configuration from. Default `config.json`
   * (relative to `<base href>`). An app below a sub path that shares the
   * session of the root app uses `'/config.json'`.
   */
  configUrl?: string;
  /**
   * Called after the configuration has been loaded and before the OIDC client
   * is configured — the place to override single values (e.g. pin
   * `postgrest.url`) without shipping a second `config.json`.
   */
  afterConfigLoaded?: (config: RuntimeConfig) => void;
}

/**
 * Returns the provider list for the auth building block. The app spreads it
 * into `bootstrapApplication(..., { providers: [...provideAuth(), ...] })`.
 *
 * Includes an app initializer that:
 *   1. loads `config.json` (runtime issuer/clientId/postgrest URL),
 *   2. configures the OIDC client + finishes the code flow.
 *
 * Returned as a flat array so the inner makeEnvironmentProviders from
 * provideHttpClient/provideOAuthClient stay at the top level — nested
 * makeEnvironmentProviders has caused DI quirks in the past.
 */
export function provideAuth(options: ProvideAuthOptions = {}): Array<Provider | EnvironmentProviders> {
  const configUrl = options.configUrl ?? DEFAULT_CONFIG_URL;
  return [
    provideHttpClient(withInterceptors([authInterceptor])),
    provideOAuthClient(),
    provideAppInitializer(() => {
      // inject() MUST run synchronously before the first await — otherwise
      // the injection context is gone (NG0203). Grab the service eagerly,
      // then return the async initialization promise.
      const auth = inject(AuthService);
      return (async () => {
        await loadRuntimeConfig(configUrl);
        options.afterConfigLoaded?.(runtimeConfig);
        await auth.init();
      })();
    })
  ];
}
