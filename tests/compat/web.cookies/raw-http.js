const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => {
    if (request.url === "/echo") {
      return request.text().then((body) => new Response("echo=" + body));
    }
    if (request.url === "/slow") {
      return new Promise((resolve) => setTimeout(() => resolve(new Response("first")), 20));
    }
    if (request.url === "/fast") return new Response("second");
    if (request.url === "/throw") throw new Error("default 500");
    const cookies = request.cookies;
    return new Response(
      "cookie=" + request.headers.get("cookie") +
      "|a=" + cookies.get("a") +
      "|b=" + cookies.get("b"),
    );
  },
});

console.log(server.url);
