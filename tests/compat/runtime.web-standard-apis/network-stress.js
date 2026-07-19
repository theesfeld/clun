// Hermetic residual stream/network stress for runtime.web-standard-apis Yes:
// large TransformStream pipe + gzip CompressionStream/DecompressionStream
// round-trip with exact byte accounting (no full intermediate retention claim
// beyond the active pipe).

const chunkSize = 32768;
const chunks = 64; // 2 MiB
let produced = 0;
let consumed = 0;

async function largeTransform() {
  const ts = new TransformStream({
    transform(chunk, controller) {
      controller.enqueue(chunk);
    },
  });
  const writer = ts.writable.getWriter();
  const reader = ts.readable.getReader();

  async function produce() {
    for (let i = 0; i < chunks; i++) {
      const u8 = new Uint8Array(chunkSize);
      u8.fill((i * 31) & 0xff);
      await writer.write(u8);
      produced += chunkSize;
    }
    await writer.close();
  }

  async function consume() {
    while (true) {
      const r = await reader.read();
      if (r.done) break;
      consumed += r.value.byteLength;
    }
  }

  await Promise.all([produce(), consume()]);
}

async function compressRoundTrip() {
  const payload = new Uint8Array(256 * 1024);
  for (let i = 0; i < payload.length; i++) payload[i] = i & 0xff;
  const cs = new CompressionStream("gzip");
  const ds = new DecompressionStream("gzip");
  const w = cs.writable.getWriter();
  const compressedReader = cs.readable.getReader();
  const dw = ds.writable.getWriter();
  const outReader = ds.readable.getReader();

  const writeP = (async () => {
    await w.write(payload);
    await w.close();
  })();

  const pipeP = (async () => {
    while (true) {
      const r = await compressedReader.read();
      if (r.done) {
        await dw.close();
        break;
      }
      await dw.write(r.value);
    }
  })();

  const readP = (async () => {
    let total = 0;
    while (true) {
      const r = await outReader.read();
      if (r.done) break;
      total += r.value.byteLength;
    }
    return total;
  })();

  await Promise.all([writeP, pipeP]);
  const total = await readP;
  if (total !== payload.length) {
    throw new Error("roundtrip-size " + total + " != " + payload.length);
  }
}

Promise.all([largeTransform(), compressRoundTrip()]).then(() => {
  if (produced !== consumed) {
    throw new Error("transform-mismatch p=" + produced + " c=" + consumed);
  }
  console.log("network-stress-ok");
  console.log(String(produced));
});
