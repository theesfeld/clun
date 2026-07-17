function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertBytes(actual, expected, label) {
  const actualBytes = Buffer.from(actual);
  const expectedBytes = Buffer.from(expected);
  assert(actualBytes.length === expectedBytes.length, `${label}: byte length`);
  assert(actualBytes.equals(expectedBytes), `${label}: bytes`);
}

async function assertOutput(output, method, expected, label) {
  if (method === "text") {
    assert(output === expected.text, `${label}: text`);
    return;
  }
  if (method === "blob") {
    assert(output.type === expected.type, `${label}: Blob type ${output.type}`);
    assert(output.size === expected.size, `${label}: Blob size ${output.size}`);
    assertBytes(await output.bytes(), expected.bytes, label);
    return;
  }
  assertBytes(output, expected.bytes, label);
}

(async () => {
  const bigBytes = new Uint8Array(4 * 1024 * 1024);
  bigBytes.fill(97);
  const specs = [
    {
      path: "/foo",
      response: new Response("foo", {
        headers: { "Content-Type": "text/plain", "X-Foo": "bar" },
      }),
      type: "text/plain",
    },
    { path: "/big", response: new Response(bigBytes), type: "" },
    {
      path: "/foo/bar",
      response: new Response("/foo/bar", {
        headers: { "Content-Type": "text/plain", "X-Foo": "bar" },
      }),
      type: "text/plain",
    },
  ];
  const routes = {};

  for (const spec of specs) {
    const blob = await spec.response.clone().blob();
    spec.expected = {
      bytes: await blob.bytes(),
      size: blob.size,
      text: await blob.text(),
      type: blob.type,
    };
    assert(spec.expected.type === spec.type, `${spec.path}: expected Blob type`);
    routes[spec.path] = spec.response;
  }

  const original = specs[0].response;
  const isolated = original.clone();
  isolated.headers.set("X-Foo", "changed");
  assert(original.headers.get("X-Foo") === "bar", "clone headers changed original");
  assert(isolated.headers.get("X-Foo") === "changed", "clone headers are not writable");
  assert(isolated.status === original.status && isolated.statusText === original.statusText, "clone status metadata");

  const server = Clun.serve({
    hostname: "127.0.0.1",
    port: 0,
    routes,
  });

  try {
    for (const spec of specs) {
      const route = `${server.url}${spec.path.substring(1)}`;
      for (const method of ["arrayBuffer", "blob", "bytes", "text"]) {
        for (const accessBody of [true, false]) {
          const batchSize = spec.path === "/big" ? 3 : 8;
          for (let iteration = 0; iteration < 2; iteration++) {
            const pending = new Array(batchSize);
            for (let index = 0; index < batchSize; index++) {
              pending[index] = fetch(route).then(async response => {
                assert(response.status === 200, `${spec.path} ${method}: status`); // contract:static.body-method-read
                assert(response.url === route, `${spec.path} ${method}: URL`);
                const contentType = response.headers.get("Content-Type");
                assert(contentType === (spec.type || null), `${spec.path} ${method}: Content-Type ${contentType}`);
                if (accessBody) void response.body;
                const output = await response[method]();
                await assertOutput(
                  output,
                  method,
                  spec.expected,
                  `${spec.path} ${method} body=${accessBody} iteration=${iteration} index=${index}`,
                );
              });
            }
            await Promise.all(pending);
          }
        }
      }
    }

    const again = await fetch(`${server.url}foo`);
    const clonedFetch = again.clone();
    assert(clonedFetch.url === again.url, "fetch clone URL");
    assert(await again.text() === "foo", "original static Response was consumed by clone");
    assert(await clonedFetch.text() === "foo", "fetch clone body");
  } finally {
    await server.stop();
  }

  console.log("server.router: static clone and concurrent body API matrix passed");
})();
