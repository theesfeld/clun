// Harness for the exact MIT-derived Bun Glob.match source at the pinned commits.
// The source body is appended mechanically by upstream-match.sh.
const Glob = Clun.Glob;
const fs = require("node:fs");
const { join } = require("node:path");
const isWindows = false;
const pendingTests = [];
let assertions = 0;
let testCount = 0;

const Bun = {
  file: function (path) {
    return {
      text: function () { return Promise.resolve(fs.readFileSync(path, "utf8")); },
    };
  },
};

function fail(actual, expected) {
  throw new Error("upstream expectation failed: " + JSON.stringify(actual) + " != " + JSON.stringify(expected));
}

function expect(actual) {
  function check(condition, expected) {
    assertions++;
    if (!condition) fail(actual, expected);
  }
  return {
    toBeTrue: function () { check(actual === true, true); },
    toBeFalse: function () { check(actual === false, false); },
    toBe: function (expected) { check(actual === expected, expected); },
    toEqual: function (expected) {
      check(JSON.stringify(actual) === JSON.stringify(expected), expected);
    },
    toBeUndefined: function () { check(actual === undefined, undefined); },
    toBeDefined: function () { check(actual !== undefined, "defined"); },
  };
}

function describe(name, fn) {
  fn();
}

function test(name, fn) {
  testCount++;
  const result = fn();
  if (result instanceof Promise) pendingTests.push(result);
}
