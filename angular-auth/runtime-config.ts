/**
 * Laufzeit-Konfiguration des generischen Auth-Bausteins.
 * Wird beim Start aus `/config.json` geladen (vom Bootstrap geschrieben),
 * sodass EIN Build gegen jede Umgebung läuft und keine Secrets im Bundle sind
 * (nur öffentliche URLs + öffentliche OIDC-clientId).
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

/** Lädt /config.json und merged es in runtimeConfig (fetch, vor DI). */
export async function loadRuntimeConfig(): Promise<void> {
  try {
    const r = await fetch('config.json', { cache: 'no-store' });
    if (!r.ok) return;
    const c = await r.json() as Partial<RuntimeConfig>;
    if (c.postgrest) Object.assign(runtimeConfig.postgrest, c.postgrest);
    if (c.oidc) Object.assign(runtimeConfig.oidc, c.oidc);
  } catch { /* keine config.json -> Build-Defaults */ }
}
