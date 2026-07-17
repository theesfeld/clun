const standalone = new Request("https://example.com/");
const shared = new Response("shared", {
  headers: [["set-cookie", "shared-manual=1"]],
});
let proxyResponsePending = false;
let proxyResponseTrapCount = 0;

const hostileResponseHandler = {
  getPrototypeOf() { proxyResponseTrapCount++; throw new Error("getPrototypeOf trap ran"); },
  setPrototypeOf() { proxyResponseTrapCount++; throw new Error("setPrototypeOf trap ran"); },
  isExtensible() { proxyResponseTrapCount++; throw new Error("isExtensible trap ran"); },
  preventExtensions() { proxyResponseTrapCount++; throw new Error("preventExtensions trap ran"); },
  getOwnPropertyDescriptor() { proxyResponseTrapCount++; throw new Error("descriptor trap ran"); },
  defineProperty() { proxyResponseTrapCount++; throw new Error("defineProperty trap ran"); },
  has() { proxyResponseTrapCount++; throw new Error("has trap ran"); },
  get() { proxyResponseTrapCount++; throw new Error("get trap ran"); },
  set() { proxyResponseTrapCount++; throw new Error("set trap ran"); },
  deleteProperty() { proxyResponseTrapCount++; throw new Error("deleteProperty trap ran"); },
  ownKeys() { proxyResponseTrapCount++; throw new Error("ownKeys trap ran"); },
  apply() { proxyResponseTrapCount++; throw new Error("apply trap ran"); },
  construct() { proxyResponseTrapCount++; throw new Error("construct trap ran"); },
};

const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/identity") {
      const requestPrototype = Object.getPrototypeOf(request);
      const cookiesDescriptor = Object.getOwnPropertyDescriptor(requestPrototype, "cookies");
      let spoofRejected = false;
      try {
        cookiesDescriptor.get.call(Object.create(requestPrototype));
      } catch (error) {
        spoofRejected = error.name === "TypeError" && error.code === "ERR_INVALID_THIS";
      }
      const identityChecks = [
        request instanceof Request,
        Object.getPrototypeOf(requestPrototype) === Request.prototype,
        Reflect.ownKeys(requestPrototype).map(String).join(",") === "cookies",
        !!cookiesDescriptor.get && cookiesDescriptor.set === undefined,
        cookiesDescriptor.enumerable && !cookiesDescriptor.configurable,
        spoofRejected,
        !Reflect.deleteProperty(requestPrototype, "cookies"),
        !Reflect.defineProperty(requestPrototype, "cookies", { value: "forged" }),
        !Reflect.set(request, "cookies", "forged"),
        !Object.prototype.hasOwnProperty.call(request, "cookies"),
        !("cookies" in standalone),
      ];

      request.headers.append("cookie", "pre=3");
      request.headers.get = () => "forged=1";
      const cookies = request.cookies;
      delete request.headers.get;
      identityChecks.push(cookies === request.cookies);
      identityChecks.push(cookies.get("a") === "1");
      identityChecks.push(cookies.get("b") === "2");
      identityChecks.push(cookies.get("pre") === "3");
      request.headers.append("cookie", "post=4");
      identityChecks.push(cookies.get("post") === null);
      cookies.set("auto", "5");
      identityChecks.push(request.headers.get("cookie") === "a=1; b=2; pre=3; post=4");

      return new Response(identityChecks.every(Boolean) ? "identity-ok" : "identity-fail", {
        headers: [["set-cookie", "manual-one=1"], ["set-cookie", "manual-two=2"]],
      });
    }

    if (pathname === "/fetch") {
      request.cookies.set("automatic", "3");
      return new Response("fetch-ok", {
        headers: [["set-cookie", "first=1"], ["set-cookie", "second=2"]],
      });
    }

    if (pathname === "/snapshot-set") {
      request.headers.set("cookie", "set-before=1");
      const cookies = request.cookies;
      const before = cookies.size === 1 && cookies.get("set-before") === "1";
      request.headers.set("cookie", "set-after=2");
      const cached = cookies.size === 1 && cookies.get("set-after") === null;
      cookies.set("map-only", "3");
      const independent = request.headers.get("cookie") === "set-after=2";
      return new Response(before && cached && independent ? "snapshot-set-ok" : "snapshot-set-fail");
    }

    if (pathname === "/snapshot-delete") {
      request.headers.delete("cookie");
      const cookies = request.cookies;
      const before = cookies.size === 0;
      request.headers.append("cookie", "after-delete=2");
      const cached = cookies.size === 0 && cookies.get("after-delete") === null;
      cookies.set("map-only", "3");
      const independent = request.headers.get("cookie") === "after-delete=2";
      return new Response(before && cached && independent ? "snapshot-delete-ok" : "snapshot-delete-fail");
    }

    if (pathname === "/shared") {
      request.cookies.set("per-request", "yes");
      return shared;
    }

    if (pathname === "/shared-check") {
      return new Response(shared.headers.getSetCookie().join("|"));
    }

    if (pathname === "/late") {
      request.cookies.set("early", "yes");
      setTimeout(() => request.cookies.set("late", "no"), 10);
      return new Response("late-ok");
    }

    if (pathname === "/async") {
      return Promise.resolve(new Response("async-ok"));
    }

    if (pathname === "/throw") {
      request.cookies.set("error-cookie", "kept");
      throw new Error("handler failure");
    }

    if (pathname === "/reject") {
      request.cookies.set("rejected-cookie", "kept");
      return Promise.reject(new Error("promised handler failure"));
    }

    if (pathname === "/fake") {
      return { status: 200, headers: new Headers(), body: "forged" };
    }

    if (pathname === "/proxy-response") {
      proxyResponsePending = true;
      proxyResponseTrapCount = 0;
      return new Proxy(new Response("proxied-body"), hostileResponseHandler);
    }

    if (pathname === "/head") {
      return new Response("head-body");
    }

    return new Response("missing", { status: 404 });
  },
  error: () => {
    if (proxyResponsePending) {
      proxyResponsePending = false;
      return new Response("fallback-proxy-" + proxyResponseTrapCount, { status: 502 });
    }
    return new Response("fallback", { status: 502 });
  },
});

console.log(server.url);
