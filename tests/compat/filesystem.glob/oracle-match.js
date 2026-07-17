const fs = require("node:fs");
const RuntimeGlob = typeof Clun === "undefined" ? Bun.Glob : Clun.Glob;
const rows = fs.readFileSync("match-corpus.tsv", "utf8").split("\n");
if (rows[rows.length - 1] === "") rows.pop();

const failures = [];
let compared = 0;
for (let index = 1; index < rows.length; index++) {
  const fields = rows[index].split("\t");
  if (fields[1] !== "stable-1.3.14") continue;
  compared++;
  const actual = new RuntimeGlob(fields[2]).match(fields[3]);
  const expected = fields[4] === "true";
  if (actual !== expected) failures.push(fields[0] + ":" + actual);
}

console.log("oracle-match", compared, "failures", failures.length);
for (const failure of failures) console.log(failure);
