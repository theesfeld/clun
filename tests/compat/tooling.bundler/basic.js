// tooling.bundler public fixture — Clun.build surface (#180)
async function main() {
  const fs = require("fs");
  const path = require("path");
  const os = require("os");

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "clun-build-fx-"));
  const entry = path.join(dir, "index.js");
  const helper = path.join(dir, "util.js");
  const outdir = path.join(dir, "dist");
  fs.mkdirSync(outdir);
  fs.writeFileSync(helper, "export const answer = 41;\nexport function inc(n){ return n + 1; }\n");
  fs.writeFileSync(entry, "import { answer, inc } from './util.js';\nexport default inc(answer);\n");

  const result = await Clun.build({
    entrypoints: [entry],
    outdir: outdir,
    format: "esm",
    minify: true,
    define: { __BUILD__: "\"fixture\"" },
    metafile: true,
    throw: false,
  });

  if (!result.success) {
    console.log("FAIL success");
    process.exit(1);
  }
  if (!Array.isArray(result.outputs) || result.outputs.length < 1) {
    console.log("FAIL outputs");
    process.exit(1);
  }
  const entryOut = result.outputs.find((o) => o.entrypoint) || result.outputs[0];
  const text = entryOut.text || "";
  if (!text.includes("__modules") && !text.includes("__require") && !text.includes("41")) {
    console.log("FAIL body");
    process.exit(1);
  }
  if (typeof result.metafile !== "string" || !result.metafile.includes("inputs")) {
    console.log("FAIL metafile");
    process.exit(1);
  }

  const analysis = await Clun.build.analyze({
    entrypoints: [entry],
    root: dir,
  });
  if (!(analysis.count >= 2)) {
    console.log("FAIL analyze");
    process.exit(1);
  }

  const sync = Clun.buildSync({
    entrypoints: [entry],
    outdir: path.join(dir, "dist2"),
    format: "cjs",
    throw: false,
  });
  if (!sync.success) {
    console.log("FAIL buildSync");
    process.exit(1);
  }

  console.log("ok");
  console.log("outputs", result.outputs.length);
  console.log("analyze", analysis.count);
  console.log("sync", sync.success);
  console.log("buildfn", typeof Clun.build);
  console.log("buildSync", typeof Clun.buildSync);
}

main();
