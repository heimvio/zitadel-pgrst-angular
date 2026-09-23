/**
 * Runtime configuration of the generic auth building block.
 * Loaded at startup from `/config.json` (written by the bootstrap), so ONE
 * build runs against any environment and no secrets are in the bundle
 * (only public URLs + the public OIDC clientId).
 */
export interface RuntimeConfig {
  postgrest: { url: string };
  oidc: {
    issuer: string;
    clientId: string;
    redirectPath: string;
    scope: string;
    /** Pfad fuer post_logout_redirect_uri (muss in der Zitadel-App
     *  whitelisted sein). Default '/': lib-bootstrap whitelistet
     *  $LOGIN_ORIGIN/ immer; Apps mit Landing-Page setzen z.B. '/welcome'. */
    postLogoutPath?: string;
  };
  /**
   * Optional: zusaetzliche Kopfzeilen fuer die `fetch`-Aufrufe dieses
   * Bausteins (`/rpc/ensure_principal`, `/rpc/whoami`). Die laufen bewusst am
   * Angular-`HttpClient` und damit an den Interceptors der App vorbei — eine
   * App, die z.B. eine Korrelations-Id auf jeden Request setzt, haette hier
   * sonst ein Loch.
   *
   * Absichtlich generisch: der Baustein kennt weder Zweck noch Namen der
   * Kopfzeilen und ruft den Rueckruf nur unmittelbar vor dem Request auf
   * (jeder Aufruf darf ein anderes Ergebnis liefern). Wird NICHT aus
   * `config.json` geladen — eine Funktion ist kein JSON; die App setzt sie
   * beim Start selbst (`runtimeConfig.extraHeaders = …`).
   */
  extraHeaders?: () => Record<string, string>;
}

export const runtimeConfig: RuntimeConfig = {
  postgrest: { url: 'http://localhost:3001' },
  oidc: {
    issuer: 'http://localhost:8090',
    clientId: '',
    redirectPath: '/callback',
    postLogoutPath: '/',
    scope: 'openid profile email urn:zitadel:iam:user:resourceowner offline_access'
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
