const fs = require("node:fs");
const rows = fs.readFileSync("match-corpus.tsv", "utf8").split("\n");
if (rows[rows.length - 1] === "") rows.pop();

const failures = [];
for (let index = 1; index < rows.length; index++) {
  const fields = rows[index].split("\t");
  const actual = new Clun.Glob(fields[2]).match(fields[3]);
  const expected = fields[4] === "true";
  if (actual !== expected) {
    failures.push(fields[0] + ": expected " + expected + ", got " + actual);
  }
}

console.log("match-corpus", rows.length - 1, "failures", failures.length);
for (const failure of failures) console.log(failure);
