const fs = require("node:fs");

function decode(kind, value) {
  if (kind === "string") return JSON.parse(value);
  if (kind === "number") return Number(value);
  if (kind === "bigint") return BigInt(value);
  if (kind === "boolean") return value === "true";
  if (kind === "null") return null;
  if (kind === "undefined") return undefined;
  if (kind === "repeated-major") return "1".repeat(Number(value)) + ".0.0";
  throw new Error("unknown argument kind: " + kind);
}

function observed(operation, left, right) {
  try {
    const value = operation === "satisfies"
      ? Clun.semver.satisfies(left, right)
      : Clun.semver.order(left, right);
    return String(value);
  } catch (error) {
    return "throw";
  }
}

const text = fs.readFileSync("bun-1.3.14-edge-matrix.tsv", "utf8");
const lines = text.trim().split("\n");
let passed = 0;
for (let index = 1; index < lines.length; index++) {
  const fields = lines[index].split("\t");
  const caseId = fields[0];
  const operation = fields[1];
  const left = decode(fields[2], fields[3]);
  const right = decode(fields[4], fields[5]);
  const expected = fields[7];
  const actual = observed(operation, left, right);
  if (actual !== expected) {
    throw new Error(caseId + ": expected " + expected + ", got " + actual);
  }
  passed++;
}

console.log("Bun 1.3.14-derived Clun edge contract passed", passed, "cases");
