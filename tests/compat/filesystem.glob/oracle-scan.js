const RuntimeGlob = typeof Clun === "undefined" ? Bun.Glob : Clun.Glob;
const root = process.env.CLUN_GLOB_ORACLE_ROOT;

function values(pattern, options) {
  return [...new RuntimeGlob(pattern).scanSync(options)].sort().join("|");
}

// Stable-shared rows only. Explicit-dot, literal-symlink, broken-entry, and
// absolute-literal corrections are named engineering/Clun expectations in
// scan.sh and adversarial.sh rather than false Bun 1.3.14 equivalence claims.
console.log("default", values("**/*.js", { cwd: root }));
console.log("dot", values("**/*.js", { cwd: root, dot: true }));
console.log("directories", values("**", { cwd: root, onlyFiles: false }));
console.log("wildcard-link", values("*/n.js", { cwd: root }));
console.log("follow-link", values("*/n.js", { cwd: root, followSymlinks: true }));
console.log("trailing-dir", values("sub/", { cwd: root, onlyFiles: false }));
console.log("trailing-globstar", values("sub/**", { cwd: root, onlyFiles: false }));
