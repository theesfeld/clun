function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

const root = "clun-shell-upstream-groups.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

function inspect(source, label, callback) {
  chain = chain.then(() => job(source).cwd(root).quiet().nothrow())
    .then(result => callback(result, label));
}

function queue(source, expectedOut, expectedCode, label, expectedErr = "") {
  inspect(source, label, (result, name) => {
    assert(result.exitCode === expectedCode, name + " exit code");
    assert(result.text() === expectedOut, name + " stdout");
    assert(stderr(result) === expectedErr, name + " stderr");
  });
}

queue("( ( ( ( echo HI! ) ) ) )", "HI!\n", 0, "multiple levels");
queue("(\n  echo HELLO! ;\n  echo HELLO AGAIN!\n)",
  "HELLO!\nHELLO AGAIN!\n", 0, "multiline subshell");
queue("(exit 42)", "", 42, "subshell exit status");
queue("(exit 42); echo hi", "hi\n", 0, "subshell exit isolation");
queue("VAR1=VALUE1\nVAR2=VALUE2\nVAR3=VALUE3\n(\n  echo $VAR1 $VAR2 $VAR3\n  VAR1='you cant'\n  VAR2='see me'\n  VAR3='my time is now'\n  echo $VAR1 $VAR2 $VAR3\n)\necho $VAR1 $VAR2 $VAR3",
  "VALUE1 VALUE2 VALUE3\nyou cant see me my time is now\nVALUE1 VALUE2 VALUE3\n",
  0, "subshell environment copy");

inspect("mkdir foo; (echo $PWD; cd foo; echo $PWD); echo $PWD",
  "subshell cwd isolation", (result, name) => {
    const lines = result.text().trim().split("\n");
    assert(result.exitCode === 0, name + " exit code");
    assert(lines.length === 3, name + " line count");
    assert(lines[1] === lines[0] + "/foo", name + " child cwd");
    assert(lines[2] === lines[0], name + " parent cwd");
    assert(stderr(result) === "", name + " stderr");
  });

const nestedClun = process.execPath;
queue(`${nestedClun} -e 'console.log(process.env.FOO)'\n(\n  export FOO=bar\n  ${nestedClun} -e 'console.log(process.env.FOO)'\n)\n${nestedClun} -e 'console.log(process.env.FOO)'`,
  "undefined\nbar\nundefined\n", 0, "subshell export isolation");

inspect("mkdir dir; (cd dir; pwd | cat | cat); pwd",
  "pipeline in subshell", (result, name) => {
    const lines = result.text().trim().split("\n");
    assert(result.exitCode === 0, name + " exit code");
    assert(lines.length === 2, name + " line count");
    assert(lines[0] === lines[1] + "/dir", name + " isolated cwd");
    assert(stderr(result) === "", name + " stderr");
  });

inspect("mkdir pipe-dir; (pwd) | cat; (cd pipe-dir; pwd) | cat; pwd",
  "subshell in pipeline", (result, name) => {
    const lines = result.text().trim().split("\n");
    assert(result.exitCode === 0, name + " exit code");
    assert(lines.length === 3, name + " line count");
    assert(lines[1] === lines[0] + "/pipe-dir", name + " child cwd");
    assert(lines[2] === lines[0], name + " parent cwd");
    assert(stderr(result) === "", name + " stderr");
  });

inspect("mkdir nested-dir; (((cd nested-dir; pwd) | cat)) | (((cat)) | cat)",
  "nested subshell pipelines", (result, name) => {
    const output = result.text().trim();
    assert(result.exitCode === 0, name + " exit code");
    assert(output.endsWith("/nested-dir"), name + " cwd");
    assert(stderr(result) === "", name + " stderr");
  });

queue("(true; exit 23)", "", 23, "ported subshell status");
queue("(echo foo;)", "foo\n", 0, "subshell trailing separator");
queue("(\necho foo\n)", "foo\n", 0, "subshell newlines");

queue("{ true; sh -c 'exit 29'; }", "", 29, "brace group status");
queue("{ echo 1; echo 2; echo 3; echo 4; } > brace-out\n{ tail -n 2; } < brace-out",
  "3\n4\n", 0, "brace group redirects");
queue("{ echo foo; }", "foo\n", 0, "brace group trailing separator");
queue("{\necho foo\n}", "foo\n", 0, "brace group newlines");
queue("if { echo foo; } then echo bar; fi", "foo\nbar\n", 0,
  "brace group as if condition");
queue("if echo foo; then { echo bar; } fi", "foo\nbar\n", 0,
  "brace group as then body");
queue("if echo foo; then { echo bar; } elif echo baz; then echo qux; fi",
  "foo\nbar\n", 0, "brace group before elif");
queue("if echo foo; then echo bar; elif { echo baz; } then echo qux; fi",
  "foo\nbar\n", 0, "brace group as elif condition");
queue("if ! echo foo; then { echo bar; } else echo baz; fi", "foo\nbaz\n", 0,
  "brace group before else");
queue("if ! echo foo; then echo bar; else { echo baz; } fi", "foo\nbaz\n", 0,
  "brace group as else body");

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-groups: 48 exact sites"));
