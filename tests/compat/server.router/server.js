let server;
const sharedStatic = new Response("shared-static");
const largeStatic = new Uint8Array(4 * 1024 * 1024);

function reloadRoutes(extraRoutes = {}) {
  server.reload({
    fetch: () => new Response("reload-fallback"),
    routes: {
      "/reload-control/:stage": reloadControl,
      ...extraRoutes,
    },
  });
}

function reloadControl(request) {
  switch (request.params.stage) {
    case "update":
      reloadRoutes({ "/reload-target": () => new Response("updated") });
      break;
    case "methods":
      reloadRoutes({
        "/reload-method": {
          GET: () => new Response("GET response"),
          POST: () => new Response("POST response"),
          PUT: () => new Response("PUT response"),
          DELETE: () => new Response("DELETE response"),
          OPTIONS: () => new Response("OPTIONS response"),
        },
      });
      break;
    case "methods-static":
      reloadRoutes({
        "/reload-method": {
          OPTIONS: new Response("OPTIONS response 2"),
          GET: () => new Response("GET response 2"),
          POST: () => new Response("POST response 2"),
          PUT: () => new Response("PUT response 2"),
          DELETE: () => new Response("DELETE response 2"),
        },
      });
      break;
    case "remove":
      reloadRoutes();
      break;
    case "static":
      server.reload({
        static: {
          "/after": new Response("after"),
          "/shared-a": sharedStatic,
        },
      });
      break;
    default:
      return new Response("unknown reload stage", { status: 400 });
  }
  return new Response(`reloaded:${request.params.stage}`);
}

let manyPattern = "/many";
for (let index = 1; index <= 65; index++) manyPattern += `/:p${index}`;

const routes = {
  "/static": new Response("static", { headers: { "x-route": "static" } }),
  "/static-created": new Response("created", {
    status: 201,
    statusText: "Created",
    headers: { "x-created": "yes" },
  }),
  "/static-explicit-type": new Response("typed", {
    headers: { "content-type": "text/foo" },
  }),
  "/static-json": Response.json({ a: 1 }),
  "/static-bytes": new Response(new Uint8Array([1, 2, 3])),
  "/static-big": new Response(largeStatic),
  "/shared-a": sharedStatic,
  "/shared-b": sharedStatic,
  "/redirect": Response.redirect("/foo/bar", 302),
  "/foo/bar": new Response("/foo/bar", { headers: { "x-foo": "bar" } }),
  "/redirect/fallback": Response.redirect("/foo/bar/fallback", 302),
  "/file": new Response(Clun.file(process.env.CLUN_ROUTER_FILE)),
  "/file-direct": Clun.file(process.env.CLUN_ROUTER_FILE),
  "/file-slice": Clun.file(process.env.CLUN_ROUTER_FILE).slice(5, 10),
  "/file-empty": new Response(Clun.file(process.env.CLUN_ROUTER_EMPTY)),
  "/file-empty-400": new Response(Clun.file(process.env.CLUN_ROUTER_EMPTY), { status: 400 }),
  "/dynamic-empty": () => new Response(Clun.file(process.env.CLUN_ROUTER_EMPTY)),
  "/file-binary": new Response(Clun.file(process.env.CLUN_ROUTER_BINARY)),
  "/file-json": new Response(Clun.file(process.env.CLUN_ROUTER_JSON)),
  "/file-unicode": new Response(Clun.file(process.env.CLUN_ROUTER_UNICODE)),
  "/file-nested": new Response(Clun.file(process.env.CLUN_ROUTER_NESTED)),
  "/file-special-name": new Response(Clun.file(process.env.CLUN_ROUTER_SPECIAL_NAME)),
  "/large-file": new Response(Clun.file(process.env.CLUN_ROUTER_LARGE)),
  "/file-custom": new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
    headers: { "x-file": "custom", "etag": '"file-custom"' },
  }),
  "/file-last-modified": new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
    headers: { "last-modified": "Wed, 21 Oct 2015 07:28:00 GMT" },
  }),
  "/file-content-range": new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
    headers: { "content-range": "bytes 0-15/100" },
  }),
  "/dynamic-file": () => new Response(Clun.file(process.env.CLUN_ROUTER_FILE)),
  "/range-after-size": () => {
    const file = Clun.file(process.env.CLUN_ROUTER_FILE);
    void file.size;
    return new Response(file);
  },
  "/dynamic-range-custom": () => new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
    headers: { "cache-control": "max-age=3600", "x-custom": "abc" },
  }),
  "/dynamic-content-range": () => new Response(Clun.file(process.env.CLUN_ROUTER_FILE), {
    headers: { "content-range": "bytes 0-15/100" },
  }),
  "/missing-file": new Response(Clun.file(process.env.CLUN_ROUTER_MISSING)),
  "/symlink-file": new Response(Clun.file(process.env.CLUN_ROUTER_SYMLINK)),
  "/special-file": new Response(Clun.file(process.env.CLUN_ROUTER_SPECIAL)),
  "/api/users": () => new Response("exact"),
  "/api/users/:id": request => new Response(`param:${request.params.id}`),
  "/api/multi/:postId/comments/:commentId": request =>
    new Response(`${request.params.postId}:${request.params.commentId}`),
  "/api/*": request => new Response(`wild:${request.params["*"]}`),
  "/method": {
    GET: request => new Response(`get:${request.method}`),
    POST: () => new Response("post"),
  },
  "/method-all": {
    GET: () => new Response("GET"),
    POST: () => new Response("POST"),
    PUT: () => new Response("PUT"),
    DELETE: () => new Response("DELETE"),
    PATCH: () => new Response("PATCH"),
    OPTIONS: () => new Response("OPTIONS"),
    HEAD: () => new Response(null, { headers: { "x-explicit-head": "handler" } }),
  },
  "/head-get": {
    GET: request => new Response("head-body", { headers: { "x-seen-method": request.method } }),
  },
  "/head-static": {
    GET: new Response("static-get"),
    HEAD: new Response(null, { headers: { "x-explicit-head": "static" } }),
  },
  "/head-mixed": {
    GET: () => new Response("mixed-get"),
    POST: new Response("mixed-post"),
  },
  "/post-only": { POST: () => new Response("post-only") },
  "/post-only-static": { POST: new Response("post-only-static") },
  "/echo-header": request => new Response(request.headers.get("x-test") || "missing"),
  "/echo-body": async request => new Response(await request.text()),
  "/echo-query": request => new Response(request.url),
  "/absolute/secret": request => new Response(request.url),
  "/async": () => Promise.resolve(new Response("async")),
  "/error": () => {
    throw new Error("route-failure");
  },
  "/async-error": async () => {
    throw new Error("async-route-failure");
  },
  "/skip": false,
  "/reload-target": () => new Response("original"),
  "/reload-control/:stage": reloadControl,
};

routes[manyPattern] = request => new Response(
  `${Object.keys(request.params).length}:${request.params.p1}:${request.params.p65}`,
);

server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  routes,
  static: {
    "/legacy-static": new Response("legacy-static"),
    "/static": new Response("legacy-must-not-win"),
  },
  fetch: request => new Response(`fallback:${request.method}:${request.url}`, { status: 202 }),
  error: error => new Response(`error:${error.message}`, { status: 500 }),
});

console.log(server.url);
