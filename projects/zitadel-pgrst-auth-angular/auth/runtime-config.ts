/**
 * Runtime configuration of the generic auth building block.
 * Loaded at startup from `/config.json` (written by the bootstrap), so ONE
 * build runs against any environment and no secrets are in the bundle
 * (only public URLs + the public OIDC clientId).
 */
export interface RuntimeConfig {
  postgrest: { url: string };
  oidc: { issuer: string; clientId: string; redirectPath: string; scope: string };
}

export const runtimeConfig: RuntimeConfig = {
  postgrest: { url: 'http://localhost:3001' },
  oidc: {
    issuer: 'http://localhost:8090',
    clientId: '',
    redirectPath: '/callback',
    scope: 'openid profile email urn:zitadel:iam:user:resourceowner'
  }
};

/** Loads /config.json and merges it into runtimeConfig (fetch, before DI). */
export async function loadRuntimeConfig(): Promise<void> {
  try {
    const r = await fetch('config.json', { cache: 'no-store' });
    if (!r.ok) return;
    const c = await r.json() as Partial<RuntimeConfig>;
    if (c.postgrest) Object.assign(runtimeConfig.postgrest, c.postgrest);
    if (c.oidc) Object.assign(runtimeConfig.oidc, c.oidc);
  } catch { /* no config.json -> build defaults */ }
}
