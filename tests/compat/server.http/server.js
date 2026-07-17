const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => {
    if (new URL(request.url).pathname === "/compat") {
      return new Response("compat-http", {
        status: 200,
        headers: { "x-clun-evidence": "present" },
      });
    }
    return new Response("missing", { status: 404 });
  },
});

console.log(server.url);
