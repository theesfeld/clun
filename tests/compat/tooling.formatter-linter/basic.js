// Shipped-binary fixture for tooling.formatter-linter FULL PORT #190.
const formatted = Clun.format("const x=1;function f(a){return a+1}");
const checkOk = Clun.format.check(formatted);
const diags = Clun.lint("debugger; var y = 1");
const rules = Clun.lint.rules();
console.log("format-ok", typeof formatted === "string" && formatted.includes("const"));
console.log("check-ok", checkOk === true);
console.log("lint-array", Array.isArray(diags) && diags.length >= 1);
console.log("has-debugger-rule", diags.some((d) => d.ruleId === "no-debugger"));
console.log("rules-count", rules.length >= 10);
console.log("format-version", Clun.format.version);
console.log("lint-version", Clun.lint.version);
