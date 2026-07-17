let server;

server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  routes: {
    "/static": new Response("static", { headers: { "x-route": "static" } }),
    "/file": new Response(Clun.file(process.env.CLUN_ROUTER_FILE)),
    "/file-direct": Clun.file(process.env.CLUN_ROUTER_FILE),
    "/file-slice": Clun.file(process.env.CLUN_ROUTER_FILE).slice(5, 10),
    "/large-file": new Response(Clun.file(process.env.CLUN_ROUTER_LARGE)),
    "/file-custom": new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
      headers: { "x-file": "custom", "etag": '"file-custom"' },
    }),
    "/file-content-range": new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
      headers: { "content-range": "bytes 0-15/100" },
    }),
    "/missing-file": new Response(Clun.file(process.env.CLUN_ROUTER_MISSING)),
    "/symlink-file": new Response(Clun.file(process.env.CLUN_ROUTER_SYMLINK)),
    "/special-file": new Response(Clun.file(process.env.CLUN_ROUTER_SPECIAL)),
    "/api/users": () => new Response("exact"),
    "/api/users/:id": request => new Response(`param:${request.params.id}`),
    "/api/*": request => new Response(`wild:${request.params["*"]}`),
    "/method": {
      GET: request => new Response(`get:${request.method}`),
      POST: () => new Response("post"),
    },
    "/async": () => Promise.resolve(new Response("async")),
    "/error": () => {
      throw new Error("route-failure");
    },
    "/skip": false,
    "/reload": () => {
      server.reload({
        routes: {
          "/after": new Response("after"),
        },
      });
      return new Response("reloaded");
    },
  },
  fetch: request => new Response(`fallback:${request.method}:${request.url}`, { status: 202 }),
  error: error => new Response(`error:${error.message}`, { status: 500 }),
});

console.log(server.url);
