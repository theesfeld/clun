// Phase 58 — security.encrypted-secrets constitutional fail-closed fixture.
// OS keychain parity is excluded by the purity contract; Clun.secrets must
// validate Bun-shaped arguments and reject store ops with ERR_SECRETS_NOT_AVAILABLE.

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
  Object.keys(secrets).join(","),
  secrets.get.name,
  secrets.get.length,
  secrets.set.name,
  secrets.set.length,
  secrets.delete.name,
  secrets.delete.length,
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

function settle(label, promise) {
  return promise.then(
    function () { return label + "|RESOLVED"; },
    function (error) {
      return label + "|" + error.name + "|" + error.code + "|" +
        (String(error.message).indexOf("purity") >= 0 ? "purity" : "other");
    },
  );
}

Promise.all([
  settle("get", secrets.get({ service: "clun-phase-58", name: "fixture" })),
  settle("set", secrets.set({
    service: "clun-phase-58",
    name: "fixture",
    value: "must-not-store",
    allowUnrestrictedAccess: true,
  })),
  settle("delete", secrets.delete({ service: "clun-phase-58", name: "fixture" })),
  settle("positional", secrets.get("clun-phase-58", "positional")),
]).then(function (lines) {
  console.log("unavailable", lines.join(" "));
});
