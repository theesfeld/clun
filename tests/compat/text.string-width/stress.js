// Million-code-unit boundedness and malformed-ANSI regression vectors.
function check(label, actual, expected) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
  return actual;
}

const ascii = "x".repeat(1000000);
const combining = "a\u0301".repeat(500000);
const ansi = "\x1b[31mx\x1b[0m".repeat(100000);
const unterminatedOsc = "x\x1b]0;" + "y".repeat(999995);
const bareEscapes = "\x1ba".repeat(500000);
const malformedCsi = "\x1b[31;\x1b[32m".repeat(100000);

const lengths = [
  ascii.length,
  combining.length,
  ansi.length,
  unterminatedOsc.length,
  bareEscapes.length,
  malformedCsi.length,
];
for (const length of lengths) {
  check("input length", length, 1000000);
}

let checksum = 0;
checksum += check("ascii", Clun.stringWidth(ascii), 1000000);
checksum += check("combining", Clun.stringWidth(combining), 500000);
checksum += check("ansi stripped", Clun.stringWidth(ansi), 100000);
checksum += check(
  "ansi counted",
  Clun.stringWidth(ansi, { countAnsiEscapeCodes: true }),
  800000,
);
checksum += check("unterminated OSC", Clun.stringWidth(unterminatedOsc), 1);
checksum += check("bare escapes", Clun.stringWidth(bareEscapes), 500000);
checksum += check("malformed CSI", Clun.stringWidth(malformedCsi), 300000);

console.log("string-width stress passed", lengths.length, "million-unit inputs", checksum);
