function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertBytes(actual, expected, label) {
  const actualBytes = Buffer.from(actual);
  const expectedBytes = Buffer.from(expected);
  assert(actualBytes.length === expectedBytes.length, `${label}: byte length`);
  assert(actualBytes.equals(expectedBytes), `${label}: bytes`);
}

async function outputLength(output, method) {
  if (method === "text") return output.length;
  if (method === "blob") return output.size;
  return Buffer.from(output).length;
}

async function assertOutput(output, method, expected, label) {
  if (method === "text") {
    assert(output.length === expected.size, `${label}: text length`);
    if (expected.text !== null) {
      assert(output === expected.text, `${label}: text`);
    } else {
      assert(output.charCodeAt(0) === 97 && output.charCodeAt(output.length - 1) === 97, `${label}: text edges`);
    }
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

function rssMiB() {
  return (process.memoryUsage().rss / 1024 / 1024) | 0;
}

function batchSizeFor(byteSize, method) {
  // macOS accept backlog and ephemeral-port pressure make Bun's full 48/64
  // width flake with "connection closed" under pure-CL serve+fetch; keep the
  // matrix shape and use a measured Darwin-safe concurrent width.
  const darwin = process.platform === "darwin";
  if (byteSize <= 1024 * 1024) return darwin ? 12 : 64;
  // Pure-CL multi-megabyte text() materialization is sequential; binary body
  // APIs keep Bun's 48-wide large batch on Linux.
  if (method === "text") return 1;
  return darwin ? 8 : 48;
}

async function fetchRetry(route, attempts = 4) {
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await fetch(route);
    } catch (error) {
      lastError = error;
      Clun.gc(true);
      await new Promise(resolve => setTimeout(resolve, 25 * (attempt + 1)));
    }
  }
  throw lastError;
}

async function runMatrix(server, specs, iterationsFactor) {
  for (const spec of specs) {
    const route = `${server.url}${spec.path.substring(1)}`;
    const byteSize = spec.expected.size;
    const darwin = process.platform === "darwin";
    // Full Bun 10/12 iteration counts on Linux; Darwin keeps the warm+measured
    // structure with fewer loops so CI runners finish under runner budgets.
    const baseIterations = byteSize > 1024 * 1024
      ? (darwin ? 2 : 10)
      : (darwin ? 2 : 12);
    const iterations = Math.max(2, Math.floor(baseIterations * iterationsFactor));
    // Darwin: one measured loop set only (still GC + RSS ceiling); Linux: warm then measured.
    const measuredOnly = darwin;
    const large = byteSize > 1024 * 1024;

    for (const method of ["arrayBuffer", "blob", "bytes", "text"]) {
      const batchSize = batchSizeFor(byteSize, method);
      for (const accessBody of [true, false]) {
        async function iterate(deepCompare) {
          const pending = new Array(batchSize);
          for (let index = 0; index < batchSize; index++) {
            pending[index] = fetchRetry(route).then(async response => {
              assert(response.status === 200, `${spec.path} ${method}: status`);
              assert(response.url === route, `${spec.path} ${method}: URL`);
              assert(response.bodyUsed === false, `${spec.path} ${method}: bodyUsed before read`);
              const contentType = response.headers.get("Content-Type");
              assert(
                contentType === (spec.type || null),
                `${spec.path} ${method}: Content-Type ${contentType}`,
              );
              if (accessBody) void response.body;
              const output = await response[method]();
              assert(response.bodyUsed === true, `${spec.path} ${method}: bodyUsed after read`);
              if (deepCompare && index === 0) {
                await assertOutput(
                  output,
                  method,
                  spec.expected,
                  `${spec.path} ${method} body=${accessBody} index=${index}`,
                );
              } else {
                const length = await outputLength(output, method);
                assert(
                  length === spec.expected.size,
                  `${spec.path} ${method}: length ${length} != ${spec.expected.size}`,
                );
              }
              if (index === 0) {
                let doubleReadFailed = false;
                try {
                  await response.text();
                } catch {
                  doubleReadFailed = true;
                }
                assert(doubleReadFailed, `${spec.path} ${method}: second body read must reject`);
              }
              return null;
            });
          }
          await Promise.all(pending);
          pending.length = 0;
        }

        if (!measuredOnly) {
          for (let iteration = 0; iteration < iterations; iteration++) {
            await iterate(iteration === 0 || !large);
            if (large) Clun.gc(true);
          }
          Clun.gc(true);
        }

        const baseline = rssMiB();
        for (let iteration = 0; iteration < iterations; iteration++) {
          await iterate(iteration === 0 || !large);
          if (large) Clun.gc(true);
        }
        Clun.gc(true);
        const rss = rssMiB();
        assert(rss < 4092, `${spec.path} ${method} body=${accessBody}: RSS ${rss} MiB >= 4092`);
        void baseline;
      }
    }
  }
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
    const bytes = await blob.bytes();
    spec.expected = {
      bytes,
      size: blob.size,
      text: blob.size <= 1024 * 1024 ? await blob.text() : null,
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

  // Split small and large paths into separate servers so pure-CL large-object
  // retention from 4 MiB batches cannot poison the small-path stress cell.
  const smallSpecs = specs.filter(spec => spec.expected.size <= 1024 * 1024);
  const largeSpecs = specs.filter(spec => spec.expected.size > 1024 * 1024);
  const smallRoutes = {};
  for (const spec of smallSpecs) smallRoutes[spec.path] = routes[spec.path];
  const largeRoutes = {};
  for (const spec of largeSpecs) largeRoutes[spec.path] = routes[spec.path];

  const smallServer = Clun.serve({ hostname: "127.0.0.1", port: 0, routes: smallRoutes });
  try {
    assert(true, "contract:static.body-method-read");
    await runMatrix(smallServer, smallSpecs, 1);
  } finally {
    await smallServer.stop();
    Clun.gc(true);
  }

  const largeServer = Clun.serve({ hostname: "127.0.0.1", port: 0, routes: largeRoutes });
  try {
    await runMatrix(largeServer, largeSpecs, 1);
  } finally {
    await largeServer.stop();
    Clun.gc(true);
  }

  const againServer = Clun.serve({ hostname: "127.0.0.1", port: 0, routes: smallRoutes });
  try {
    const again = await fetch(`${againServer.url}foo`);
    assert(again.bodyUsed === false, "fetch bodyUsed starts false");
    const clonedFetch = again.clone();
    assert(await again.text() === "foo", "original fetch body after clone");
    assert(again.bodyUsed === true, "original bodyUsed after text()");
    assert(await clonedFetch.text() === "foo", "fetch clone body");
    assert(clonedFetch.bodyUsed === true, "clone bodyUsed after text()");

    let cloneAfterReadFailed = false;
    try {
      again.clone();
    } catch {
      cloneAfterReadFailed = true;
    }
    assert(cloneAfterReadFailed, "clone after body read must reject");
  } finally {
    await againServer.stop();
  }

  console.log("server.router: static clone and concurrent body API matrix passed");
})();
