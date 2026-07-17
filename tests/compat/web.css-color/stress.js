let checksum = 2166136261;
for (let index = 0; index < 20000; index++) {
  const r = (index * 17) & 255;
  const g = (index * 73) & 255;
  const b = (index * 151) & 255;
  const value = Clun.color([r, g, b, index & 255], "number");
  checksum ^= value;
  checksum = Math.imul(checksum, 16777619) >>> 0;
}
console.log("repeat", 20000, checksum.toString(16).padStart(8, "0"));

const hostile = [
  "x".repeat(1048577),
  "\u{1f600}".repeat(524289),
  `rgb(${"1".repeat(129)} 0 0)`,
  `${"rgb(".repeat(33)}0 0 0${")".repeat(33)}`,
  "rgb(1e999 0 0)",
  "color(display-p3 1 2 3) trailing",
];
let rejected = 0;
for (const input of hostile) {
  if (Clun.color(input) === null) rejected++;
}
console.log("bounded-rejections", rejected, hostile.length);

let alphaHash = 2166136261;
for (let alpha = 0; alpha < 256; alpha++) {
  const string = Clun.color([1, 2, 3, alpha], "rgba");
  const object = Clun.color([1, 2, 3, alpha], "{rgba}");
  const text = `${string}|${object.a};`;
  for (let index = 0; index < text.length; index++) {
    alphaHash ^= text.charCodeAt(index);
    alphaHash = Math.imul(alphaHash, 16777619) >>> 0;
  }
}
console.log("alpha-f32", 256, alphaHash.toString(16).padStart(8, "0"));

let projectionRoundTrips = 0;
for (let r = 0; r < 256; r += 37) {
  for (let g = 0; g < 256; g += 53) {
    for (let b = 0; b < 256; b += 61) {
      const input = { r, g, b };
      const expected = Clun.color(input, "hex");
      for (const format of ["hsl", "lab"]) {
        const projection = Clun.color(input, format);
        const actual = Clun.color(projection, "hex");
        if (actual !== expected) {
          throw new Error(`${format} round trip failed: ${expected} -> ${projection} -> ${actual}`);
        }
        projectionRoundTrips++;
      }
    }
  }
}
console.log("projection-roundtrips", projectionRoundTrips);

let ansiShapes = 0;
for (let r = 0; r < 256; r += 17) {
  for (let g = 0; g < 256; g += 17) {
    for (let b = 0; b < 256; b += 17) {
      const ansi16 = Clun.color({ r, g, b }, "ansi-16");
      const ansi256 = Clun.color({ r, g, b }, "ansi-256");
      if (!/^\u001b\[(3[0-7]|9[0-7])m$/.test(ansi16)) {
        throw new Error(`invalid ansi-16: ${JSON.stringify(ansi16)}`);
      }
      const match = /^\u001b\[38;5;(\d+)m$/.exec(ansi256);
      if (!match || Number(match[1]) > 255) {
        throw new Error(`invalid ansi-256: ${JSON.stringify(ansi256)}`);
      }
      ansiShapes++;
    }
  }
}
console.log("ansi-shapes", ansiShapes);
