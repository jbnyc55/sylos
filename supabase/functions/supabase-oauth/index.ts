// supabase-oauth — the one-tap-setup token relay. DEVELOPER infrastructure:
// this function runs on the Sylos developer's own project, never on a
// user's. It exists because the OAuth client secret cannot ship inside the
// iOS binary: the app sends the authorization code (plus its PKCE
// verifier) here, and this function — the only holder of the secret —
// exchanges it with Supabase for the user's Management API tokens and
// hands them straight back. Nothing is stored; every call is stateless.
//
// Credentials, in order of preference:
//   1. Edge Function secrets SUPA_OAUTH_CLIENT_ID / SUPA_OAUTH_CLIENT_SECRET
//   2. The host project's Vault, via the service_role-only RPC
//      public.oauth_relay_creds() (the auto-injected service role key
//      makes this deployable without the secrets CLI)
//
// With neither available, every call answers 500 "relay not configured" —
// which is also why this file being present in user forks is harmless.
//
// verify_jwt is off (config.toml): callers are the Sylos app before any
// project exists. The relay grants nothing by itself — an authorization
// code is single-use, PKCE-bound to the app that started the flow, and
// tokens go only to that caller.
//
// Several clients share it: the iOS app, whose callback is the sylos://
// scheme, and the browser flows at getsylos.com — the web app at /app and
// the desktop setup flow at /setup — which run the same exchange in the
// browser. A browser flow marks itself in the OAuth `state` (`web:<nonce>`
// from the web app, `setup:<nonce>` from the setup flow, `local:<nonce>`
// from a dev server), and GET /callback sends that browser back to the
// flow's own return address — a fixed allow-list below, never a URL taken
// from the request, so the callback can't be turned into an open redirect.
// The POST routes answer CORS preflights for the same reason: a browser
// has to be able to call them, and possession of the relay URL still
// grants nothing without a fresh, PKCE-bound code.

const TOKEN_URL = "https://api.supabase.com/v1/oauth/token";
const MGMT_API = "https://api.supabase.com";
const APP_SCHEME = "sylos://supabase-oauth";
// Where a web flow lands after consent, by state prefix. WEB_CALLBACK_URL
// and SETUP_CALLBACK_URL override the production addresses (a preview
// deployment, say).
const WEB_RETURNS: Record<string, string> = {
  web: Deno.env.get("WEB_CALLBACK_URL") ?? "https://getsylos.com/app/oauth",
  setup: Deno.env.get("SETUP_CALLBACK_URL") ?? "https://getsylos.com/setup/oauth",
  local: "http://localhost:5173/app/oauth",
};

const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
};

// The /mgmt passthrough answers every method the Management API takes,
// and the browser client reads retry-after off 429s.
const MGMT_CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-expose-headers": "retry-after",
  "access-control-max-age": "86400",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

let cachedCreds: { id: string; secret: string } | null = null;

async function getCreds(): Promise<{ id: string; secret: string } | null> {
  const envId = Deno.env.get("SUPA_OAUTH_CLIENT_ID");
  const envSecret = Deno.env.get("SUPA_OAUTH_CLIENT_SECRET");
  if (envId && envSecret) return { id: envId, secret: envSecret };
  if (cachedCreds) return cachedCreds;
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return null;
  const res = await fetch(`${url}/rest/v1/rpc/oauth_relay_creds`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      authorization: `Bearer ${serviceKey}`,
      "content-type": "application/json",
    },
    body: "{}",
  });
  if (!res.ok) return null;
  const data = await res.json().catch(() => null);
  if (data?.client_id && data?.client_secret) {
    cachedCreds = { id: data.client_id, secret: data.client_secret };
  }
  return cachedCreds;
}

Deno.serve(async (req) => {
  // GET /callback — the registered OAuth redirect. Supabase requires an
  // HTTPS callback URL, and the app needs the browser back: this route
  // simply forwards the code (or error) into the app's custom scheme,
  // which completes the in-app auth session. No secrets involved.
  if (req.method === "GET" && new URL(req.url).pathname.endsWith("/callback")) {
    const params = new URL(req.url).searchParams;
    const forward = new URLSearchParams();
    for (const key of ["code", "state", "error", "error_description"]) {
      const value = params.get(key);
      if (value) forward.set(key, value);
    }
    // A web flow says so in its state; everything else is the iOS app.
    const prefix = (params.get("state") ?? "").split(":")[0];
    const webReturn = WEB_RETURNS[prefix];
    return new Response(null, {
      status: 302,
      headers: { location: `${webReturn ?? APP_SCHEME}?${forward}` },
    });
  }

  // /mgmt/v1/… — the Management API passthrough for the browser flows.
  // api.supabase.com's own CORS allowlist reflects only Supabase's
  // origins, so getsylos.com can't call it directly; this route forwards
  // the call verbatim — the caller's bearer token, path, query and body —
  // and relays the answer with CORS open. The relay adds no credential of
  // its own here: without the caller's valid Management API token,
  // upstream answers 401, so possession of this URL still grants nothing.
  const reqUrl = new URL(req.url);
  const mgmtAt = reqUrl.pathname.indexOf("/mgmt/");
  if (mgmtAt !== -1) {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: MGMT_CORS_HEADERS });
    }
    const subpath = reqUrl.pathname.slice(mgmtAt + "/mgmt".length);
    if (!subpath.startsWith("/v1/")) {
      return new Response(JSON.stringify({ error: "only /v1 paths are relayed" }), {
        status: 404,
        headers: { "content-type": "application/json", ...MGMT_CORS_HEADERS },
      });
    }
    const headers: Record<string, string> = {};
    const auth = req.headers.get("authorization");
    if (auth) headers.authorization = auth;
    const contentType = req.headers.get("content-type");
    if (contentType) headers["content-type"] = contentType;
    const body = req.method === "GET" || req.method === "HEAD" ? undefined : await req.arrayBuffer();
    const upstream = await fetch(`${MGMT_API}${subpath}${reqUrl.search}`, {
      method: req.method,
      headers,
      body,
    });
    const respHeaders: Record<string, string> = { ...MGMT_CORS_HEADERS };
    const upstreamType = upstream.headers.get("content-type");
    if (upstreamType) respHeaders["content-type"] = upstreamType;
    const retryAfter = upstream.headers.get("retry-after");
    if (retryAfter) respHeaders["retry-after"] = retryAfter;
    const payload = await upstream.arrayBuffer();
    // 204/304 must carry no body, or the Response constructor throws.
    return new Response(upstream.status === 204 || upstream.status === 304 ? null : payload, {
      status: upstream.status,
      headers: respHeaders,
    });
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") return json(405, { error: "POST only" });

  const creds = await getCreds();
  if (!creds) {
    return json(500, { error: "relay not configured" });
  }

  let body: Record<string, string>;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "the request body must be JSON" });
  }

  const params = new URLSearchParams();
  if (body.action === "exchange") {
    if (!body.code || !body.code_verifier || !body.redirect_uri) {
      return json(400, { error: "exchange needs code, code_verifier and redirect_uri" });
    }
    params.set("grant_type", "authorization_code");
    params.set("code", body.code);
    params.set("code_verifier", body.code_verifier);
    params.set("redirect_uri", body.redirect_uri);
  } else if (body.action === "refresh") {
    if (!body.refresh_token) {
      return json(400, { error: "refresh needs refresh_token" });
    }
    params.set("grant_type", "refresh_token");
    params.set("refresh_token", body.refresh_token);
  } else {
    return json(400, { error: "action must be exchange or refresh" });
  }

  const upstream = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      accept: "application/json",
      authorization: `Basic ${btoa(`${creds.id}:${creds.secret}`)}`,
    },
    body: params,
  });

  const data = await upstream.json().catch(() => ({}));
  if (!upstream.ok) {
    return json(upstream.status, {
      error: data.error_description ?? data.message ?? data.error ??
        `token exchange failed (${upstream.status})`,
    });
  }
  // Only the token fields ride back — never echo the credentials.
  return json(200, {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_in: data.expires_in,
    token_type: data.token_type,
  });
});
