// examples/serve.ts — a Clun.serve smoke (run: `clun examples/serve.ts`, then curl /,
// /json, POST /echo). TypeScript annotations are stripped (Phase 09); URL objects are
// Phase 18, so we route on the req.url string.

const server = Clun.serve({
  port: 3000,
  hostname: "127.0.0.1",
  fetch: async (req: Request) => {
    if (req.url === "/") return new Response("Hello from Clun.serve!\n");
    if (req.url === "/json") return Response.json({ ok: true, method: req.method });
    if (req.method === "POST" && req.url === "/echo") {
      const body = await req.text();
      return new Response("echo: " + body + "\n", { headers: { "x-echo": "1" } });
    }
    return new Response("not found\n", { status: 404 });
  },
  error: (e: Error) => new Response("server error: " + e.message + "\n", { status: 500 }),
});

console.log(`clun serving on ${server.url}`);
