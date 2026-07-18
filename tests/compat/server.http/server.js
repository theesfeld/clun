const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 10,
  maxRequestBodySize: 1024 * 1024,
  fetch: async (request) => {
    const path = new URL(request.url).pathname;
    if (path === "/compat") {
      return new Response("compat-http", {
        status: 200,
        headers: { "x-clun-evidence": "present" },
      });
    }
    if (path === "/stream") {
      return new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("stream-yes"));
            controller.close();
          },
        }),
      );
    }
    if (path === "/echo" && request.method === "POST") {
      const text = await request.text();
      return new Response("echo:" + text);
    }
    return new Response("missing", { status: 404 });
  },
});

console.log(server.url);
