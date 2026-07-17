let server;

server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  routes: {
    "/static": new Response("static", { headers: { "x-route": "static" } }),
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
