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
console.log(typeof EventTarget);
console.log(typeof FormData);
console.log(typeof File);
console.log(typeof CompressionStream);
console.log(typeof ByteLengthQueuingStrategy);
console.log(typeof performance.now);
console.log(typeof atob);
console.log(typeof crypto.subtle.digest);
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

  const fd = new FormData();
  fd.append("k", "v");
  console.log(fd.get("k"));

  const file = new File([new TextEncoder().encode("hi")], "hi.txt", {
    type: "text/plain",
  });
  console.log(file.name);
  console.log(file.size === 2);

  const et = new EventTarget();
  let fired = false;
  et.addEventListener("ping", () => {
    fired = true;
  });
  et.dispatchEvent(new CustomEvent("ping", { detail: 1 }));
  console.log(fired === true);

  console.log(btoa("hi") === "aGk=");
  console.log(atob("aGk=") === "hi");

  const cs = new CountQueuingStrategy({ highWaterMark: 4 });
  console.log(cs.highWaterMark === 4);
  console.log(cs.size() === 1);

  const gz = new CompressionStream("gzip");
  const gw = gz.writable.getWriter();
  const gr = gz.readable.getReader();
  const readGz = gr.read();
  await gw.write(new TextEncoder().encode("compress-me"));
  await gw.close();
  const gzChunk = await readGz;
  console.log(gzChunk.done === false && gzChunk.value.byteLength > 0);

  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode("abc"),
  );
  console.log(digest.byteLength === 32);

  console.log(typeof performance.now() === "number");

  const body = await response.text();
  console.log(body);
}

main();
