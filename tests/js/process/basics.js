console.log(process.platform, process.arch, typeof process.pid === "number");
console.log(process.versions.node);
console.log(typeof process.cwd(), typeof process.hrtime === "function");
console.log("v" + process.versions.node === process.version);
