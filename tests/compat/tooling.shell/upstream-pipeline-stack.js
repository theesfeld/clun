function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

const root = "clun-shell-upstream-pipeline-stack.tmp";
const external = "/usr/bin/env";
let chain = Promise.resolve();

function inspect(jobFactory, label, callback) {
  chain = chain.then(() => jobFactory().quiet().nothrow().then(result => callback(result, label)));
}

function queue(jobFactory, expectedOut, expectedCode, label, expectedErr = "") {
  inspect(jobFactory, label, (result, name) => {
    assert(result.exitCode === expectedCode, name + " exit code");
    assert(result.text() === expectedOut, name + " stdout");
    assert(stderr(result) === expectedErr, name + " stderr");
  });
}

queue(() => Clun.$`rm -rf ${root}; mkdir -p ${root}`, "", 0, "root setup");

queue(() => Clun.$`true | true`, "", 0, "true true");
queue(() => Clun.$`false | false`, "", 1, "false false");
queue(() => Clun.$`true | false`, "", 1, "true false");
queue(() => Clun.$`false | true`, "", 0, "false true");
queue(() => Clun.$`true | true | true | true`, "", 0, "true chain");
queue(() => Clun.$`false | false | false | false`, "", 1, "false chain");
queue(() => Clun.$`true | false | true | false`, "", 1, "alternating chain");

queue(() => Clun.$`echo hello | echo world`, "world\n", 0, "echo pair");
queue(() => Clun.$`echo hello | echo world | echo final`, "final\n", 0, "echo chain");
queue(() => Clun.$`echo test | true`, "", 0, "echo true");
queue(() => Clun.$`echo test | false`, "", 1, "echo false");
queue(() => Clun.$`echo one | echo two | true | echo three`, "three\n", 0,
  "echo mixed chain");

queue(() => Clun.$`exit 0 | echo after`, "after\n", 0, "exit zero first");
queue(() => Clun.$`exit 42 | echo after`, "after\n", 0, "exit nonzero first");
queue(() => Clun.$`echo before | exit 0`, "", 0, "exit zero last");
queue(() => Clun.$`echo before | exit 99`, "", 99, "exit nonzero last");
queue(() => Clun.$`exit 5 | exit 10 | exit 15`, "", 15, "exit chain");

inspect(() => Clun.$`cd / | pwd`.cwd(root), "cd isolation", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  assert(result.text().endsWith("/" + root + "\n"), name + " cwd");
  assert(stderr(result) === "", name + " stderr");
});
inspect(() => Clun.$`mkdir foo; mkdir foo/bar; cd foo | cd foo/bar | pwd`.cwd(root),
  "multiple cd isolation", (result, name) => {
    assert(result.exitCode === 0, name + " exit code");
    assert(result.text().endsWith("/" + root + "\n"), name + " cwd");
  });
// pwd | cd | pwd: first pwd writes into the pipe discarded by cd; only the last
// pwd reaches pipeline stdout. cwd isolation still keeps the path under root
// (Bun TestBuilder predicate for two lines does not call expect() on its boolean).
inspect(() => Clun.$`pwd | cd / | pwd`.cwd(root), "pwd cd pwd isolation", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  assert(result.text().endsWith("/" + root + "\n"), name + " cwd");
  assert(stderr(result) === "", name + " stderr");
});
queue(() => Clun.$`echo hello | ${external} cat`, "hello\n", 0,
  "builtin external passthrough");
queue(() => Clun.$`${external} printf hello | echo world`, "world\n", 0,
  "external builtin");
queue(() => Clun.$`true | ${external} true`, "", 0, "builtin external zero");
queue(() => Clun.$`false | ${external} true`, "", 0, "external status wins");
queue(() => Clun.$`echo one | true | ${external} cat | false`, "", 1,
  "mixed pipeline status");

queue(() => Clun.$`true | true | true | true | true | true | true | true | true | true`,
  "", 0, "ten true commands");
queue(() => Clun.$`echo 1 | echo 2 | echo 3 | echo 4 | echo 5 | echo 6 | echo 7 | echo 8 | echo 9 | echo 10`,
  "10\n", 0, "ten echo commands");
queue(() => Clun.$`true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false`,
  "", 1, "twenty alternating commands");
queue(() => Clun.$`(true | true) | (false | false) | (true | true)`, "", 0,
  "grouped status pipelines");
queue(() => Clun.$`(echo a | echo b) | (echo c | echo d) | (echo e | echo f)`,
  "f\n", 0, "grouped echo pipelines");

queue(() => Clun.$`true | true && echo done`, "done\n", 0, "pipeline and");
queue(() => Clun.$`false | false || echo fallback`, "fallback\n", 0, "pipeline or");
queue(() => Clun.$`true | true; echo after`, "after\n", 0, "pipeline sequence");
queue(() => Clun.$`(true | true); echo after`, "after\n", 0, "group sequence");
queue(() => Clun.$`true | true; false | false; echo done`, "done\n", 0,
  "multiple pipelines");
queue(() => Clun.$`echo a | echo b && echo c | echo d && echo e | echo f`,
  "b\nd\nf\n", 0, "pipeline and chain");
queue(() => Clun.$`false | false || echo a | echo b || echo c | echo d`, "b\n", 0,
  "pipeline or chain");

queue(() => Clun.$`[[ -n "test" ]] | true && echo ok`, "ok\n", 0,
  "condition then builtin");
queue(() => Clun.$`true | [[ -n "test" ]] && echo ok`, "ok\n", 0,
  "builtin then condition");
queue(() => Clun.$`true | true; true | true; true | true; true | true; true | true; echo done`,
  "done\n", 0, "rapid pipelines");

queue(() => Clun.$`echo "" | echo ""`, "\n", 0, "empty echo");
queue(() => Clun.$`echo "   " | echo "   "`, "   \n", 0, "space echo");
queue(() => Clun.$`echo | echo | echo`, "\n", 0, "no argument echo");

queue(() => Clun.$`cd /nonexistent 2>/dev/null | echo after`, "after\n", 0,
  "cd error pipeline");
queue(() => Clun.$`which nonexistent_command 2>/dev/null | echo after`, "after\n", 0,
  "which error pipeline");
queue(() => Clun.$`basename | echo after 2>/dev/null`, "after\n", 0,
  "basename error pipeline", "usage: basename string\n");

queue(() => Clun.$`(true | (true | (true | true)))`, "", 0, "deep group");
queue(() => Clun.$`((echo a | echo b) | (echo c | echo d)) | echo e`, "e\n", 0,
  "nested group pipelines");
queue(() => Clun.$`echo $(true | true | echo nested) | echo outer`, "outer\n", 0,
  "pipeline command substitution");
queue(() => Clun.$`true | $(echo echo) result`, "result\n", 0,
  "command substitution command");
queue(() => Clun.$`(true | false) && (echo a | echo b) || (echo c | echo d)`,
  "d\n", 0, "conditional groups");

queue(() => Clun.$`VAR=test true | echo $VAR`, "\n", 0, "command assignment isolation");
queue(() => Clun.$`export VAR=test | echo $VAR`, "\n", 0, "export isolation");
queue(() => Clun.$`seq 1 3 | echo done`, "done\n", 0, "seq echo");
queue(() => Clun.$`seq 1 5 | true`, "", 0, "seq true");
queue(() => Clun.$`seq 1 2 | seq 3 4`, "3\n4\n", 0, "seq pair");
queue(() => Clun.$`yes | head -n 1`, "y\n", 0, "yes head one");
queue(() => Clun.$`yes no | head -n 2`, "no\nno\n", 0, "yes head two");
queue(() => Clun.$`yes | true`, "", 0, "yes true");
queue(() => Clun.$`yes | false`, "", 1, "yes false");

queue(() => Clun.$`rm -rf ${root}`, "", 0, "root cleanup");
chain.then(() => console.log("upstream-pipeline-stack: 120 exact sites"));
