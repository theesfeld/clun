const url = new URL("/items?limit=2", "https://example.com/base/");
const headers = new Headers();
headers.set("x-clun-evidence", "present");
const response = new Response("web-body", { status: 201, headers });

console.log(url.href);
console.log(response.status);
console.log(response.headers.get("x-clun-evidence"));
console.log(typeof ReadableStream);
console.log(typeof WritableStream);
console.log(typeof TransformStream);
console.log(response.body != null && typeof response.body.getReader === "function");

const streamResponse = new Response("stream-chunk");
void streamResponse.body;

async function main() {
  const chunk = await streamResponse.body.getReader().read();
  console.log(chunk.done === false);
  console.log(new TextDecoder().decode(chunk.value));
  console.log(streamResponse.bodyUsed === true);

  const byobView = new Uint8Array(4);
  const byobSource = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("byob"));
      c.close();
    },
  });
  const byob = await byobSource.getReader({ mode: "byob" }).read(byobView);
  console.log(new TextDecoder().decode(byob.value));

  const ts = new TransformStream({
    transform(chunk, controller) {
      controller.enqueue(
        new TextEncoder().encode(new TextDecoder().decode(chunk).toUpperCase()),
      );
    },
  });
  const w = ts.writable.getWriter();
  const readP = ts.readable.getReader().read();
  await w.write(new TextEncoder().encode("ok"));
  await w.close();
  const out = await readP;
  console.log(new TextDecoder().decode(out.value));

  const body = await response.text();
  console.log(body);
}

main();
