// Issue #179 — security.encrypted-secrets full port fixture.
// Pure-CL AES-256-GCM vault: Bun.secrets get/set/delete parity plus has/list/clear.
// Compat harness sets CLUN_SECRETS_PATH/KEY for a hermetic vault.

function errorSummary(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + "|" + error.code + "|" + error.message;
  }
}

const secrets = Clun.secrets;
console.log(
  "api",
  typeof secrets,
  Object.keys(secrets).sort().join(","),
  secrets.backend,
  secrets.get.name,
  secrets.get.length,
  secrets.set.name,
  secrets.set.length,
  secrets.delete.name,
  secrets.delete.length,
  secrets.has.name,
  secrets.list.name,
  secrets.clear.name,
);

console.log(
  "invalid",
  errorSummary(function () { secrets.get({ name: "only" }); }),
  errorSummary(function () { secrets.get({ service: "", name: "x" }); }),
  errorSummary(function () { secrets.set({ service: "s", name: "n" }); }),
  errorSummary(function () { secrets.set({ service: "s", name: "n", value: 1 }); }),
  errorSummary(function () { secrets.set("s", "n"); }),
  errorSummary(function () { secrets.set("s", "n", 1); }),
);

const service = "clun-179-fixture";
const name = "fixture-account";
const lines = [];

function push(label) {
  return function (value) {
    lines.push(label + "|" + value);
  };
}

secrets
  .set({
    service: service,
    name: name,
    value: "stored-secret",
    allowUnrestrictedAccess: true,
  })
  .then(function () { lines.push("set|ok"); })
  .then(function () { return secrets.get({ service: service, name: name }); })
  .then(push("get"))
  .then(function () { return secrets.has({ service: service, name: name }); })
  .then(push("has"))
  .then(function () { return secrets.get({ service: service, name: "missing" }); })
  .then(function (v) { lines.push("missing|" + (v === null ? "null" : v)); })
  .then(function () { return secrets.get(service, "positional-never"); })
  .then(function (v) { lines.push("positional|" + (v === null ? "null" : v)); })
  .then(function () { return secrets.set(service, "positional", "pos-value"); })
  .then(function () { return secrets.get(service, "positional"); })
  .then(push("posget"))
  .then(function () { return secrets.list({ service: service }); })
  .then(function (rows) {
    lines.push(
      "list|" + rows.length + "|" +
        rows.map(function (r) { return r.name; }).sort().join(","),
    );
  })
  .then(function () { return secrets.delete({ service: service, name: name }); })
  .then(push("del"))
  .then(function () { return secrets.delete({ service: service, name: name }); })
  .then(push("del2"))
  .then(function () {
    return secrets.set({ service: service, name: "positional", value: "" });
  })
  .then(function () { return secrets.has(service, "positional"); })
  .then(push("emptyDel"))
  .then(function () { return secrets.clear(service); })
  .then(push("clear"))
  .then(function () {
    console.log("ops", lines.join(" "));
  })
  .catch(function (error) {
    console.log("fail", error.name, error.code, error.message);
  });
