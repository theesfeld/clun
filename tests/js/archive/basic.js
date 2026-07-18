// tests/js/archive/basic.js — Clun.gzipSync / Archive / zipSync smoke (Issue #134).

function check(cond, label) {
  if (!cond) throw new Error("archive check failed: " + label);
}

async function main() {
  const plain = "hello archives";
  const gz = Clun.gzipSync(plain);
  check(gz[0] === 0x1f && gz[1] === 0x8b, "gzip magic");
  check(new TextDecoder().decode(Clun.gunzipSync(gz)) === plain, "gunzip");

  const def = Clun.deflateSync(plain);
  check(new TextDecoder().decode(Clun.inflateSync(def)) === plain, "inflate");

  const archive = new Clun.Archive({ "a.txt": "alpha", "b/c.txt": "beta" });
  const bytes = await archive.bytes();
  check(bytes instanceof Uint8Array && bytes.length >= 1024, "tar bytes");
  const files = await archive.files();
  check(files.size === 2, "files size");
  check((await files.get("a.txt").text()) === "alpha", "a.txt");

  const gzArch = new Clun.Archive({ "x.txt": "x" }, { compress: "gzip" });
  const gzb = await gzArch.bytes();
  check(gzb[0] === 0x1f && gzb[1] === 0x8b, "archive gzip magic");
  const again = new Clun.Archive(gzb);
  check((await (await again.files()).get("x.txt").text()) === "x", "gzip files");

  let zstdFailed = false;
  try {
    Clun.zstdCompressSync("x");
  } catch (e) {
    zstdFailed = String(e.message || e).includes("zstd");
  }
  check(zstdFailed, "zstd fail-closed");

  const zip = Clun.zipSync({ "z.txt": "zipped" });
  const uz = Clun.unzipSync(zip);
  check(new TextDecoder().decode(uz["z.txt"]) === "zipped", "zip roundtrip");

  console.log("archive-ok");
}

main().catch((e) => {
  console.error(e && e.message ? e.message : e);
  process.exitCode = 1;
});
