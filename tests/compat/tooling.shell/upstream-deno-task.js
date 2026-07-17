function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

const root = "clun-shell-upstream-deno-task.tmp";
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

function queueFile(source, path, expected, label, expectedOut = "") {
  queue(source, expectedOut, 0, label + " command");
  queue(`cat ${path}`, expected, 0, label + " file");
}

queue("echo 1", "1\n", 0, "echo one");
queue("echo 1 2   3", "1 2 3\n", 0, "unquoted spaces");
queue('echo "1 2   3"', "1 2   3\n", 0, "quoted spaces");
queue("echo 1 2\\ \\ \\ 3", "1 2   3\n", 0, "escaped spaces");
queue('echo "1 2\\ \\ \\ 3"', "1 2\\ \\ \\ 3\n", 0,
  "double-quoted backslashes");
queue("echo test$(echo 1    2)", "test1 2\n", 0, "unquoted substitution fields");
queue('echo test$(echo "1    2")', "test1 2\n", 0, "unquoted substitution collapse");
queue('echo "test$(echo "1    2")"', "test1    2\n", 0, "quoted substitution spaces");
queue('echo test$(echo "1 2 3")', "test1 2 3\n", 0, "compound substitution");
queue("VAR=1 /usr/bin/env sh -c 'printf \"%s\\n\" \"$VAR\"' && echo $VAR",
  "1\n\n", 0, "command-local variable");
queue("VAR=1 VAR2=2 /usr/bin/env sh -c 'printf \"%s%s\\n\" \"$VAR\" \"$VAR2\"'",
  "12\n", 0, "multiple command-local variables");
queue("EMPTY= /usr/bin/env sh -c 'printf \"EMPTY: %s\\n\" \"$EMPTY\"'",
  "EMPTY: \n", 0, "empty command-local variable");
queue('\"echo\" \"1\"', "1\n", 0, "quoted command");
queue("echo test-dashes", "test-dashes\n", 0, "dashes");
queue("echo 'a/b'/c", "a/b/c\n", 0, "compound path word");
queue(`echo 'a/b'ctest\\"te  st\\"'asdf'`, 'a/bctest"te st"asdf\n', 0,
  "mixed quotations");
queue(`echo --test=\\"2\\" --test='2' test\\"TEST\\" TEST'test'TEST 'test''test' test'test'\\"test\\" \\"test\\"\\"test\\"'test'`,
  '--test="2" --test=2 test"TEST" TESTtestTEST testtest testtest"test" "test""test"test\n',
  0, "dense quotations");

queue("echo 1 && echo 2 || echo 3", "1\n2\n", 0, "and or");
queue("echo 1 || echo 2 && echo 3", "1\n3\n", 0, "or and");
queue("echo 1 || (echo 2 && echo 3)", "1\n", 0, "short-circuit group");
queue("false || false || (echo 2 && false) || echo 3", "2\n3\n", 0,
  "group fallback");
queue("echo 1 || (echo 2 && echo 3)", "1\n", 0, "conditional group");
queue("false || false || (echo 2 && false) || echo 3", "2\n3\n", 0,
  "conditional group fallback");
queue("echo $(echo 1)", "1\n", 0, "nested substitution");
queue("echo $(echo 1 && echo 2)", "1 2\n", 0, "conditional substitution");

queue("VAR=1 && echo $VAR$VAR", "11\n", 0, "shell variable concatenation");
queue("echo $VAR && export VAR=1 && echo $VAR && /usr/bin/env sh -c 'printf \"%s\\n\" \"$VAR\"'",
  "\n1\n1\n", 0, "exported variable");
queue('export VAR=1 VAR2=testing VAR3="test this out" && echo $VAR $VAR2 $VAR3',
  "1 testing test this out\n", 0, "multiple exports");

queue("echo 1 | /usr/bin/env cat", "1\n", 0, "basic external pipe");
queue("echo 1 | echo 2 && echo 3", "2\n3\n", 0, "pipe conditional");
queue("echo 2 | echo 1 | /usr/bin/env cat", "1\n", 0, "multiple pipes");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"2\\n\" >&2' | /usr/bin/env cat",
  "1\n", 0, "subprocess pipe", "2\n");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"2\\n\" >&2' |& /usr/bin/env cat",
  "1\n2\n", 0, "merged subprocess pipe");
queueFile("echo 1 | /usr/bin/env cat > pipe-out.txt", "pipe-out.txt", "1\n",
  "pipe stdout redirect");
queueFile("echo 1 | /usr/bin/env sh -c 'cat >&2' 2> pipe-err.txt", "pipe-err.txt", "1\n",
  "pipe stderr redirect");
queue("ls . | echo hi", "hi\n", 0, "broken pipe builtin");
queue("/usr/bin/env printf 'source\\n' | echo hi", "hi\n", 0, "broken pipe subprocess");
queue("/usr/bin/env sh -c 'exit 1' | /usr/bin/env printf 'hi\\n'", "hi\n", 0,
  "last pipeline status success");
queue("ls missing-deno-task | /usr/bin/env printf 'hi\\n'", "hi\n", 0,
  "producer failure status", "ls: missing-deno-task: No such file or directory\n");
queue("missing-deno-task-command | /usr/bin/env printf 'hi\\n'", "hi\n", 0,
  "missing producer status", "clun: command not found: missing-deno-task-command\n");
queue("echo hi | /usr/bin/env sh -c 'exit 69'", "", 69, "last pipeline status failure");

queue("echo 1 | echo 2 | echo 3 | echo 4 | echo 5 | /usr/bin/env cat", "5\n", 0,
  "deep pipeline");
queue("echo start | echo 1 | echo 2 | echo 3 | echo 4 | echo 5 | echo 6 | echo 7 | echo 8 | echo 9 | echo 10 | echo 11 | echo 12 | echo 13 | echo 14 | echo 15 | /usr/bin/env cat",
  "15\n", 0, "very deep pipeline");
queue("echo outer | (echo inner1 | echo inner2) | /usr/bin/env cat", "inner2\n", 0,
  "nested pipeline group");
queue("echo $(echo nested | echo pipe) | /usr/bin/env cat", "pipe\n", 0,
  "nested pipeline substitution");
queue("(echo a | echo b) | (echo c | echo d) | /usr/bin/env cat", "d\n", 0,
  "multiple pipeline groups");
queue("echo test | (echo inner | echo nested && echo after) | /usr/bin/env cat",
  "nested\nafter\n", 0, "conditional nested pipeline");
queue("echo start | (echo l1 | (echo l2 | (echo l3 | echo final))) | /usr/bin/env cat",
  "final\n", 0, "deeply nested pipeline");
queue("echo 1 | echo 2 | echo 3 | false | echo 4 | /usr/bin/env cat", "4\n", 0,
  "pipeline failure unwind");
queue("echo a | echo b && echo c | echo d | /usr/bin/env cat", "b\nd\n", 0,
  "interleaved pipelines");
queue("echo 1 | echo 2; echo 3 | echo 4; echo 5 | echo 6 | /usr/bin/env cat",
  "2\n4\n6\n", 0, "rapid pipelines");
queue("echo start | missing-pipeline-command | echo after || echo fallback", "after\n", 0,
  "pipeline error propagation", "clun: command not found: missing-pipeline-command\n");
queue("(echo success | echo works) | (missing-nested-command | echo backup) || echo final_fallback",
  "backup\n", 0, "nested pipeline recovery",
  "clun: command not found: missing-nested-command\n");

let longBuiltin = "echo 0";
for (let index = 1; index < 50; index++) longBuiltin += " | echo " + index;
longBuiltin += " | /usr/bin/env cat";
queue(longBuiltin, "49\n", 0, "long builtin pipeline");

let longCat = "echo 0";
for (let index = 0; index < 50; index++) longCat += " | cat";
longCat += " | /usr/bin/env cat";
queue(longCat, "0\n", 0, "long cat pipeline");

queue("echo outer | (echo inner1 | echo inner2 | (echo deep1 | echo deep2) | echo inner3) | echo final | /usr/bin/env cat",
  "final\n", 0, "complex nested pipeline");
queue("echo start | (echo pause; echo resume) | echo end | /usr/bin/env cat", "end\n", 0,
  "pipeline interruption");
queue("echo level0 | (echo level1 | (echo level2 | (echo level3 | (echo level4 | (echo level5 | (echo level6 | (echo level7 | (echo level8 | (echo level9 | (echo level10 | (echo level11 | (echo level12 | (echo level13 | (echo level14 | (echo level15 | (echo level16 | (echo level17 | (echo level18 | (echo level19 | echo deep_final))))))))))))))))))) | /usr/bin/env cat",
  "deep_final\n", 0, "extremely deep nested pipeline");
queue("echo start | (echo n1 | echo n2 | echo n3 | (echo deep1 | echo deep2 | echo deep3 | (echo deeper1 | echo deeper2 | echo deeper3 | (echo deepest1 | echo deepest2 | echo deepest_final)))) | /usr/bin/env cat",
  "deepest_final\n", 0, "pathological nested pipeline");

queueFile("echo 5 6 7 > basic.txt", "basic.txt", "5 6 7\n", "basic redirect");
queueFile("echo 1 2 3 && echo 1 > and.txt", "and.txt", "1\n", "redirect after and",
  "1 2 3\n");
queue("mkdir -p subdir && cd subdir && echo 1 2 3 > test.txt", "", 0,
  "redirect after cd");
queue("cat subdir/test.txt", "1 2 3\n", 0, "redirect after cd file");
queueFile('echo 1 2 3 > "$PWD/absolute.txt"', "absolute.txt", "1 2 3\n",
  "expanded redirect path");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"5\\n\" >&2' 1> stdout.txt",
  "", 0, "external stdout redirect", "5\n");
queue("cat stdout.txt", "1\n", 0, "external stdout file");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"5\\n\" >&2' 2> stderr.txt",
  "1\n", 0, "external stderr redirect");
queue("cat stderr.txt", "5\n", 0, "external stderr file");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"5\\n\" >&2' 2> /dev/null",
  "1\n", 0, "stderr dev null");
queueFile("echo 1 > append.txt && echo 2 >> append.txt", "append.txt", "1\n2\n",
  "append redirect");
queue("/usr/bin/env sh -c 'printf \"1\\n\"; printf \"23\\n\" >&2' &> both.txt && /usr/bin/env sh -c 'printf \"456\\n\"; printf \"789\\n\" >&2' &>> both.txt",
  "", 0, "merged redirects");
queue("cat both.txt", "1\n23\n456\n789\n", 0, "merged redirect file");
inspect("echo 1 > $EMPTY", "ambiguous redirect", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(result.text() === "", name + " stdout");
  assert(stderr(result).includes("redirect"), name + " stderr");
});
queueFile("echo foo bar > input.txt; cat < input.txt", "input.txt", "foo bar\n",
  "input redirect", "foo bar\n");
queue("/usr/bin/env sh -c 'printf \"Stdout\\n\"; printf \"Stderr\\n\" >&2' 2>&1",
  "Stdout\nStderr\n", 0, "stderr to stdout");
queue("/usr/bin/env sh -c 'printf \"Stdout\\n\"; printf \"Stderr\\n\" >&2' 1>&2",
  "", 0, "stdout to stderr", "Stdout\nStderr\n");
queue("/usr/bin/env sh -c 'printf \"Stdout\\n\"; printf \"Stderr\\n\" >&2' 2>&1",
  "Stdout\nStderr\n", 0, "quiet stderr to stdout");
queue("/usr/bin/env sh -c 'printf \"Stdout\\n\"; printf \"Stderr\\n\" >&2' 1>&2",
  "", 0, "quiet stdout to stderr", "Stdout\nStderr\n");
queue("echo hi > /dev/null", "", 0, "builtin dev null");
queue("/usr/bin/env printf 'Hello friends\\n' > /dev/null", "", 0,
  "subprocess dev null");
queue(`${process.execPath} exec 'echo nested-clun' > /dev/null`, "", 0,
  "nested clun dev null");

inspect("mkdir -p pwd-sub; pwd && cd pwd-sub && pwd && cd ../ && pwd", "pwd sequence",
  (result, name) => {
    const lines = result.text().trim().split("\n");
    assert(result.exitCode === 0, name + " exit code");
    assert(lines.length === 3, name + " line count");
    assert(lines[1] === lines[0] + "/pwd-sub", name + " child cwd");
    assert(lines[2] === lines[0], name + " restored cwd");
    assert(stderr(result) === "", name + " stderr");
  });

chain = chain.then(() => job("echo $FOO").env({ FOO: "bar" }).quiet().nothrow())
  .then(result => {
    assert(result.exitCode === 0, "job env exit code");
    assert(result.text() === "bar\n", "job env stdout");
    assert(stderr(result) === "", "job env stderr");
  });
for (let index = 0; index < 2; index++) {
  chain = chain.then(() => job("BUN_TEST_VAR=1 /usr/bin/env")
    .env({ FOO: "bar" }).quiet().nothrow()).then(result => {
      const lines = result.text().trim().split("\n").sort();
      assert(result.exitCode === 0, "subprocess job env exit code " + index);
      assert(lines.length === 2, "subprocess job env size " + index);
      assert(lines[0] === "BUN_TEST_VAR=1" && lines[1] === "FOO=bar",
        "subprocess job env values " + index);
      assert(stderr(result) === "", "subprocess job env stderr " + index);
    });
}

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-deno-task: 156 exact sites"));
