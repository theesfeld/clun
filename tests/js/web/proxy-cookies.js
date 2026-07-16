function check(condition, label) {
  if (!condition) throw new Error("proxy cookie check failed: " + label);
}

function invalidThisWithoutTraps(fn, counter, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === "TypeError", label + " error type");
    check(counter.value === 0, label + " no traps");
    return;
  }
  throw new Error("proxy cookie check failed: " + label + " did not throw");
}

function hostileHandler(counter) {
  return {
    ownKeys() { counter.value++; throw new Error("ownKeys trap ran"); },
    getOwnPropertyDescriptor() { counter.value++; throw new Error("descriptor trap ran"); },
    get() { counter.value++; throw new Error("get trap ran"); },
  };
}

for (const target of [{ a: 1 }, [["array", "value"]], [], function targetFunction() {}]) {
  const counter = { value: 0 };
  const map = new Clun.CookieMap(new Proxy(target, hostileHandler(counter)));
  check(map.size === 0, "proxy initializer is empty");
  check(counter.value === 0, "proxy initializer invokes no traps");
}

const revokedCounter = { value: 0 };
const revoked = Proxy.revocable({ a: 1 }, hostileHandler(revokedCounter));
revoked.revoke();
const revokedMap = new Clun.CookieMap(revoked.proxy);
check(revokedMap.size === 0 && revokedCounter.value === 0, "revoked proxy initializer");

const dateCounter = { value: 0 };
const date = new Date(0);
Object.defineProperty(date, "getTime", {
  get() { dateCounter.value++; throw new Error("Date getter ran"); },
});
const proxiedDate = new Proxy(date, {
  get() { dateCounter.value++; throw new Error("Date proxy trap ran"); },
});
invalidThisWithoutTraps(
  () => new Clun.Cookie("date", "value", { expires: proxiedDate }),
  dateCounter,
  "proxied Date constructor rejection",
);
const expiry = new Clun.Cookie("date", "value");
invalidThisWithoutTraps(
  () => { expiry.expires = proxiedDate; },
  dateCounter,
  "proxied Date setter rejection",
);

const responseCounter = { value: 0 };
const proxiedResponse = new Proxy(new Response("body"), {
  get() { responseCounter.value++; throw new Error("Response proxy trap ran"); },
});
invalidThisWithoutTraps(
  () => Response.prototype.text.call(proxiedResponse),
  responseCounter,
  "proxied Response rejection",
);

console.log("proxy-cookie-contract ok");
