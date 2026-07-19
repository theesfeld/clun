// Issue #187 — runtime.loader-plugins full port fixture.
// Bun.plugin-compatible Clun.plugin: onResolve/onLoad/module/clearAll + exceed list/clear.

function summary(fn) {
  try {
    return "OK:" + String(fn());
  } catch (error) {
    return "ERR:" + error.name;
  }
}

const plugin = Clun.plugin;
const names = [];

console.log(
  "api",
  typeof plugin,
  typeof plugin.clearAll,
  typeof plugin.clear,
  typeof plugin.list,
  typeof plugin.registerHooks,
);

plugin({
  name: "fixture-object",
  setup(build) {
    names.push("setup-object");
    const chained = build.onResolve({ filter: /^fixture:obj$/, namespace: "file" }, () => ({
      path: "obj",
      namespace: "fixture",
    }));
    names.push(chained === build ? "chain-resolve" : "no-chain-resolve");
    build.onLoad({ filter: /.*/, namespace: "fixture" }, () => ({
      exports: { value: 11, tag: "object-loader" },
      loader: "object",
    }));
  },
});

plugin({
  name: "fixture-virtual",
  setup(build) {
    names.push("setup-virtual");
    build.module("fixture:virtual", () => ({
      exports: { value: 22, tag: "virtual" },
      loader: "object",
    }));
  },
});

plugin({
  name: "fixture-js",
  setup(build) {
    build.onResolve({ filter: /^fixture:js$/, namespace: "file" }, () => ({
      path: "jsmod",
      namespace: "jsns",
    }));
    build.onLoad({ filter: /.*/, namespace: "jsns" }, () => ({
      contents: "module.exports = { value: 33, tag: 'js-contents' };",
      loader: "js",
    }));
  },
});

const listed = plugin.list().slice().sort().join(",");
console.log("list", listed);

const o = require("fixture:obj");
const v = require("fixture:virtual");
const j = require("fixture:js");
console.log("loads", o.value, o.tag, v.value, v.tag, j.value, j.tag);

// clear one plugin; a never-before-required specifier from that plugin must fail
plugin.clear("fixture-js");
console.log(
  "clear-one",
  plugin.list().indexOf("fixture-js") < 0 ? "gone" : "still",
  summary(function () {
    // fresh specifier still routed by missing plugin
    return require("fixture:js-after-clear");
  }).startsWith("ERR:") ? "blocked" : "alive",
);

plugin.clearAll();
console.log(
  "clear-all",
  plugin.list().length,
  summary(function () {
    return require("fixture:brand-new-after-clear");
  }).startsWith("ERR:") ? "blocked" : "alive",
);

// Re-register after clear for text loader + file transform
plugin({
  name: "text",
  setup(build) {
    build.onResolve({ filter: /^fixture:text$/, namespace: "file" }, () => ({
      path: "body",
      namespace: "textns",
    }));
    build.onLoad({ filter: /.*/, namespace: "textns" }, () => ({
      contents: "hello-text",
      loader: "text",
    }));
  },
});

const t = require("fixture:text");
console.log("text", t.default);

console.log("setup-trace", names.join(","));
