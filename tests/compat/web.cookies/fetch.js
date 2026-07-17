function check(condition, label) {
  if (!condition) throw new Error("web.cookies fetch: " + label);
}

(async () => {
  const base = process.argv[2];
  check(typeof base === "string", "base URL argument");
  const response = await fetch(base + "fetch");
  check(response.status === 200 && response.ok, "response status");
  check((await response.text()) === "fetch-ok", "response body");
  check(
    response.headers.get("set-cookie") === "first=1, second=2, automatic=3; Path=/; SameSite=Lax",
    "joined Set-Cookie view",
  );
  check(
    response.headers.getAll("set-cookie").join("|") ===
      "first=1|second=2|automatic=3; Path=/; SameSite=Lax",
    "getAll Set-Cookie view",
  );
  check(
    response.headers.getSetCookie().join("|") ===
      "first=1|second=2|automatic=3; Path=/; SameSite=Lax",
    "getSetCookie view",
  );
  // Phase 28 plain-HTTP pooling keeps the listener keep-alive by default, so the
  // Connection field is keep-alive rather than close. Set-Cookie multiplicity is
  // the contract under test; Connection remains a single ordered field.
  check(
    [...response.headers].map((entry) => entry.join(":")).join("|") ===
      "connection:keep-alive|content-length:8|content-type:text/plain;charset=utf-8|date:" + response.headers.get("date") +
      "|set-cookie:first=1|set-cookie:second=2|set-cookie:automatic=3; Path=/; SameSite=Lax",
    "entries view",
  );
  check(
    [...response.headers.keys()].join("|") ===
      "connection|content-length|content-type|date|set-cookie|set-cookie|set-cookie",
    "keys view",
  );
  check(
    [...response.headers.values()].slice(-3).join("|") ===
      "first=1|second=2|automatic=3; Path=/; SameSite=Lax",
    "values view",
  );
  const fields = [];
  response.headers.forEach((value, name, owner) => {
    if (name === "set-cookie") fields.push(value + ":" + (owner === response.headers));
  });
  check(fields.join("|") === "first=1:true|second=2:true|automatic=3; Path=/; SameSite=Lax:true", "forEach view");
  console.log("web.cookies fetch ok");
})();
