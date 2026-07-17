function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

const executable = process.execPath;
const root = "clun-shell-upstream-positionals.tmp";
const shortScript = root + "/positionals.bun.sh";
const tenScript = root + "/positionals2.bun.sh";
const absoluteShort = process.cwd() + "/" + shortScript;
const absoluteTen = process.cwd() + "/" + tenScript;
const shortSource = "#!/bin/sh\n\necho $0\necho $1\necho $2$2\n";
const tenSource =
  "#!/bin/sh\n\necho $0\necho $1\necho $2$2\necho $3\necho $4\n" +
  "echo $5\necho $6\necho $7\necho $8\necho $9\necho $10\n";

function run(script, args = []) {
  return Clun.$`${executable} run ${script} ${args}`.quiet().nothrow();
}

function check(result, expected, label) {
  assert(result.exitCode === 0, label + " exit code " + result.exitCode +
    " stderr " + JSON.stringify(stderr(result)));
  assert(result.text() === expected,
    label + " stdout " + JSON.stringify(result.text()) + " !== " + JSON.stringify(expected));
  assert(stderr(result) === "", label + " stderr " + JSON.stringify(stderr(result)));
}

let chain = Clun.$`rm -rf ${root}; mkdir -p ${root}`.quiet();

function checkApplicationPositionals(index) {
  if (index >= process.argv.length) return Promise.resolve();
  return Clun.$`echo $${{ raw: String(index) }}`.text()
    .then(output => {
      assert(output === process.argv[index] + "\n",
        "$" + index + " application positional");
      return checkApplicationPositionals(index + 1);
    });
}

chain = chain
  .then(() => checkApplicationPositionals(0))
  .then(() => Clun.$`cat < ${Buffer.from(shortSource)} > ${shortScript}`.quiet())
  .then(() => Clun.$`cat < ${Buffer.from(tenSource)} > ${tenScript}`.quiet())
  .then(() => run(shortScript, ["a", "b", "c"]))
  .then(result => check(result, absoluteShort + "\na\nbb\n", "standalone"))
  .then(() => run(shortScript))
  .then(result => check(result, absoluteShort + "\n\n\n", "not enough args"))
  .then(() => run(tenScript,
    ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]))
  .then(result => check(result,
    absoluteTen + "\na\nbb\nc\nd\ne\nf\ng\nh\ni\na0\n", "only ten"))
  .then(() => run(tenScript, ["キ", "テ", "ィ", "・", "ホ", "ワ", "イ", "ト"]))
  .then(result => check(result,
    absoluteTen + "\nキ\nテテ\nィ\n・\nホ\nワ\nイ\nト\n\nキ0\n", "non-ASCII"))
  .then(() => Clun.$`rm -rf ${root}`.quiet())
  .then(() => console.log("upstream-positionals: 10 exact sites"));
