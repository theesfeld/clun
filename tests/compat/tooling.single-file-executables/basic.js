// Issue #181 — tooling.single-file-executables full port surface fixture.
// Proves Clun.build / Clun.compile API shape (compile path exceeding Bun).

const compile = Clun.compile;
const build = Clun.build;

console.log(
  "api",
  typeof build,
  typeof compile,
  typeof compile.executable,
  typeof compile.registerTemplate,
  typeof compile.verify,
  typeof compile.listTemplates,
);

const templates = compile.listTemplates();
console.log("templates", typeof templates, Object.keys(templates).sort().join(","));
