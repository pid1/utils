// Serves setup.sh as text/plain at every path on rx.pid1.space.
//
// Static assets alone would not do: the file has to answer at the bare
// hostname, and `.sh` is not a content type anyone wants guessed. So the
// script ships as an asset -- keeping setup.sh the single source of truth,
// verifiable by build.sh before it ever reaches a root shell -- and this
// handler decides the URL and the headers.

const SCRIPT = "/setup.sh";
const BUILD_ID = "/.build-id";

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed\n", {
        status: 405,
        headers: { allow: "GET, HEAD" },
      });
    }

    const url = new URL(request.url);

    // The deploy fallback in .github/workflows/cf-fallback.yml reads this to
    // decide whether Cloudflare already published the current commit. It must
    // never be cached, or the fallback would deploy on top of a good build.
    if (url.pathname === BUILD_ID) {
      const id = await env.ASSETS.fetch(new URL(BUILD_ID, url));
      return new Response(id.ok ? id.body : "unknown\n", {
        status: 200,
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }

    const asset = await env.ASSETS.fetch(new URL(SCRIPT, url));
    if (!asset.ok) return new Response("not found\n", { status: 404 });

    return new Response(request.method === "HEAD" ? null : asset.body, {
      status: 200,
      headers: {
        "content-type": "text/plain; charset=utf-8",
        // Short enough that a fix reaches people the same morning, long
        // enough that reinstalling a few machines does not refetch each time.
        "cache-control": "public, max-age=300",
        "x-content-type-options": "nosniff",
      },
    });
  },
};
