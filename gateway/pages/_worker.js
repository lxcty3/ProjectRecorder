const ALLOWED_PREFIXES = [
  "/auth/v1",
  "/rest/v1",
  "/realtime/v1",
  "/storage/v1",
  "/functions/v1",
];

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, accept, x-client-info, " +
    "x-supabase-api-version, prefer, range, x-upsert, cache-control, " +
    "x-requested-with",
  "Access-Control-Expose-Headers": "content-range, content-length, location",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin, Access-Control-Request-Headers",
};

function withCors(response, requestHeaders) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(CORS_HEADERS)) {
    headers.set(name, value);
  }
  const requested = requestHeaders.get("access-control-request-headers");
  if (requested) headers.set("Access-Control-Allow-Headers", requested);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...CORS_HEADERS,
    },
  });
}


const GITHUB_ROUTES = [
  {
    prefix: "/github/",
    upstream: "https://github.com",
    allowed: "lxcty3/ProjectRecorder.git",
  },
  {
    prefix: "/github-api/",
    upstream: "https://api.github.com",
    allowed: "repos/lxcty3/ProjectRecorder",
  },
  {
    prefix: "/github-upload/",
    upstream: "https://uploads.github.com",
    allowed: "repos/lxcty3/ProjectRecorder",
  },
];

function githubRoute(pathname) {
  return GITHUB_ROUTES.find((route) => {
    if (!pathname.startsWith(route.prefix)) return false;
    const rest = pathname.slice(route.prefix.length);
    return rest === route.allowed || rest.startsWith(route.allowed + "/");
  });
}

function rewriteGithubLocation(location, requestUrl, route) {
  if (!location) return location;
  try {
    const target = new URL(location);
    const upstream = new URL(route.upstream);
    if (target.origin !== upstream.origin) return location;
    return requestUrl.origin + route.prefix + target.pathname.slice(1) + target.search;
  } catch {
    return location;
  }
}

async function proxyGithub(request, url, route) {
  const rest = url.pathname.slice(route.prefix.length);
  const target = new URL(route.upstream + "/" + rest + url.search);
  const headers = new Headers(request.headers);
  for (const name of [
    "host", "cf-connecting-ip", "cf-ipcountry", "cf-ray", "cf-visitor",
  ]) headers.delete(name);

  const hasBody = !["GET", "HEAD"].includes(request.method);
  let response;
  try {
    response = await fetch(target.toString(), {
      method: request.method,
      headers,
      body: hasBody ? request.body : undefined,
      redirect: "manual",
    });
  } catch (error) {
    return json({ error: "github_unreachable", message: String(error) }, 502);
  }

  const outHeaders = new Headers(response.headers);
  const location = outHeaders.get("location");
  if (location) {
    outHeaders.set("location", rewriteGithubLocation(location, url, route));
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: outHeaders,
  });
}

function allowedPath(pathname) {
  return ALLOWED_PREFIXES.some(
    (prefix) => pathname === prefix || pathname.startsWith(prefix + "/"),
  );
}

function upstreamUrl(env, pathname, search) {
  const base = new URL(String(env.SUPABASE_URL || "https://edchntmyqqjqvpngylgc.supabase.co").trim());
  const target = new URL(base.origin);
  target.pathname = pathname;
  target.search = search;
  return target;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }), request.headers);
    }

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "projectrecorder-gateway" });
    }

    const ghRoute = githubRoute(url.pathname);
    if (ghRoute) return proxyGithub(request, url, ghRoute);

    if (!allowedPath(url.pathname)) {
      return json({ error: "unsupported_path" }, 404);
    }

    let target;
    try {
      target = upstreamUrl(env, url.pathname, url.search);
    } catch (error) {
      return json({ error: "gateway_misconfigured" }, 500);
    }

    const headers = new Headers(request.headers);
    headers.delete("host");
    headers.delete("cf-connecting-ip");
    headers.delete("cf-ipcountry");
    headers.delete("cf-ray");
    headers.delete("cf-visitor");

    const hasBody = !["GET", "HEAD"].includes(request.method);
    let upstream;
    try {
      upstream = await fetch(target.toString(), {
        method: request.method,
        headers,
        body: hasBody ? request.body : undefined,
      });
    } catch (error) {
      return json({
        error: "upstream_unreachable",
        message: String(error && error.message || error),
      }, 502);
    }

    if (upstream.webSocket) return upstream;
    return withCors(upstream, request.headers);
  },
};
