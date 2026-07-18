// Hermetic large-transfer / stress evidence for runtime.web-standard-apis.
// Streams 8 MiB through TransformStream + BYOB without retaining the full body.

const chunkSize = 65536;
const chunks = 128; // 8 MiB
let produced = 0;
let consumed = 0;

const ts = new TransformStream({
  transform(chunk, controller) {
    controller.enqueue(chunk);
  },
});

const writer = ts.writable.getWriter();
const reader = ts.readable.getReader({ mode: "byob" });

async function produce() {
  for (let i = 0; i < chunks; i++) {
    const u8 = new Uint8Array(chunkSize);
    u8.fill((i * 17) & 0xff);
    await writer.write(u8);
    produced += chunkSize;
  }
  await writer.close();
}

async function consume() {
  while (true) {
    const view = new Uint8Array(chunkSize);
    const result = await reader.read(view);
    if (result.done) break;
    consumed += result.value.byteLength;
  }
}

Promise.all([produce(), consume()]).then(() => {
  if (produced !== consumed) {
    throw new Error("produced=" + produced + " consumed=" + consumed);
  }
  console.log("stress-ok");
  console.log(String(produced));
});
