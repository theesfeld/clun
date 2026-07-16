// Exercise every strict-mode vector reachable through the public two-argument API.
// Loose/includePrerelease rows remain covered by tests/lisp/install/semver-tests.lisp.
const fs = require("node:fs");

function load(name) {
  return JSON.parse(fs.readFileSync("../../fixtures/semver/" + name + ".json", "utf8"));
}

function usesUnsupportedOptions(row) {
  const options = row[2];
  return options === true || (options && (options.loose || options.includePrerelease));
}

function check(condition, fixture, index, detail) {
  if (!condition) {
    throw new Error(fixture + "[" + index + "]: " + detail);
  }
}

let assertions = 0;
let rows = load("valid-versions");
for (let i = 0; i < rows.length; i++) {
  const version = rows[i][0];
  check(Clun.semver.order(version, version) === 0, "valid-versions", i, version);
  assertions++;
}

rows = load("comparisons");
for (let i = 0; i < rows.length; i++) {
  const row = rows[i];
  if (!usesUnsupportedOptions(row)) {
    check(Clun.semver.order(row[0], row[1]) === 1, "comparisons", i, "forward");
    check(Clun.semver.order(row[1], row[0]) === -1, "comparisons", i, "reverse");
    assertions += 2;
  }
}

rows = load("equality");
for (let i = 0; i < rows.length; i++) {
  const row = rows[i];
  if (!usesUnsupportedOptions(row)) {
    check(Clun.semver.order(row[0], row[1]) === 0, "equality", i, "build ignored");
    assertions++;
  }
}

rows = load("range-include");
for (let i = 0; i < rows.length; i++) {
  const row = rows[i];
  if (!usesUnsupportedOptions(row)) {
    check(Clun.semver.satisfies(row[1], row[0]) === true, "range-include", i, row[1]);
    assertions++;
  }
}

rows = load("range-exclude");
for (let i = 0; i < rows.length; i++) {
  const row = rows[i];
  if (!usesUnsupportedOptions(row)) {
    check(Clun.semver.satisfies(row[1], row[0]) === false, "range-exclude", i, String(row[1]));
    assertions++;
  }
}

rows = load("invalid-versions");
for (let i = 0; i < rows.length; i++) {
  check(
    Clun.semver.satisfies(rows[i][0], "*") === false,
    "invalid-versions",
    i,
    String(rows[i][0]),
  );
  assertions++;
}

rows = load("range-parse");
for (let i = 0; i < rows.length; i++) {
  const row = rows[i];
  if (row[1] === null && !usesUnsupportedOptions(row)) {
    check(Clun.semver.satisfies("1.2.3", row[0]) === false, "range-parse", i, row[0]);
    assertions++;
  }
}

console.log("node-semver public strict corpus passed", assertions, "assertions");
