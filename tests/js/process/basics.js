console.log(
  process.platform === "linux" || process.platform === "darwin",
  process.arch === "x64" || process.arch === "arm64",
  typeof process.pid === "number",
);
console.log(process.versions.node);
console.log(typeof process.cwd(), typeof process.hrtime === "function");
console.log("v" + process.versions.node === process.version);
