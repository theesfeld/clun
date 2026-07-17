(async () => {
  const routeOnly = Clun.serve({
    hostname: "127.0.0.1",
    port: 0,
    routes: { "/test": () => new Response("route") },
  });

  let missingFetchRejected = false;
  try {
    await routeOnly.fetch("/test");
  } catch (error) {
    missingFetchRejected = error instanceof TypeError &&
      error.message === "fetch() requires the server to have a fetch handler";
  }
  await routeOnly.stop();
  if (!missingFetchRejected) throw new Error("route-only server.fetch did not reject correctly");

  let mock;
  mock = Clun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
      return new Response(`${request.method}:${request.url}:${server === mock}`);
    },
  });
  const response = await mock.fetch("/mock?x=1");
  const body = await response.text();
  await mock.stop();

  if (body !== `GET:${mock.url}mock?x=1:true`) {
    throw new Error(`unexpected server.fetch response: ${body}`);
  }
  console.log("server.router: server.fetch API passed");
})();
