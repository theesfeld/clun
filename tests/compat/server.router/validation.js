function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function throws(message, callback) {
  try {
    callback();
  } catch (error) {
    assert(String(error.message).includes(message), `unexpected error: ${error.message}`);
    return;
  }
  throw new Error(`expected error containing ${message}`);
}

throws("Route parameter names cannot start with a number", () => {
  Clun.serve({ routes: { "/test/:123": () => new Response("bad") } });
});
throws("Support for duplicate route parameter names", () => {
  Clun.serve({ routes: { "/test/:same/:same": () => new Response("bad") } });
});
throws("Route wildcards must be the final segment", () => {
  Clun.serve({ routes: { "/test/*/tail": () => new Response("bad") } });
});
throws("Route values must be", () => {
  Clun.serve({ routes: { "/test": 123 } });
});
throws("requires a fetch function or at least one active route", () => {
  Clun.serve({ routes: {} });
});
throws("requires a fetch function or at least one active route", () => {
  Clun.serve({ routes: undefined });
}); // contract:serve.validation.requires-dispatch
throws("Invalid redirect status code", () => {
  Response.redirect("/target", 200);
});

console.log("server.router: validation matrix passed");
