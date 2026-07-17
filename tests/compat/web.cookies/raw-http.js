const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/echo") {
      return request.text().then((body) => new Response("echo=" + body));
    }
    if (pathname === "/slow") {
      return new Promise((resolve) => setTimeout(() => resolve(new Response("first")), 20));
    }
    if (pathname === "/fast") return new Response("second");
    if (pathname === "/throw") throw new Error("default 500");
    const cookies = request.cookies;
    return new Response(
      "cookie=" + request.headers.get("cookie") +
      "|a=" + cookies.get("a") +
      "|b=" + cookies.get("b"),
    );
  },
});

console.log(server.url);
