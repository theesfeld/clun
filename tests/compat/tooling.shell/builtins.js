function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function check(job, expectedCode, expectedOut, expectedErr, label) {
  return job.quiet().nothrow().then(result => {
    assert(result.exitCode === expectedCode, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    assert(stderr(result) === expectedErr, label + " stderr");
  });
}

check(Clun.$`basename`, 1, "", "usage: basename string\n", "basename usage")
  .then(() => check(
    Clun.$`basename js/bun/shell/commands/basename.test.ts /home/tux/example.txt /catalog/ / C:/Documents/Newsletters/Summer2018.pdf`,
    0,
    "basename.test.ts\nexample.txt\ncatalog\n/\nSummer2018.pdf\n",
    "",
    "basename values",
  ))
  .then(() => {
    console.log("basename");
    return check(Clun.$`dirname`, 1, "", "usage: dirname string\n", "dirname usage");
  })
  .then(() => check(
    Clun.$`dirname js/bun/shell/commands/dirname.test.ts /home/tux/example.txt /catalog/ / C:/Documents/Newsletters/Summer2018.pdf`,
    0,
    "js/bun/shell/commands\n/home/tux\n/\n/\nC:/Documents/Newsletters\n",
    "",
    "dirname values",
  ))
  .then(() => {
    console.log("dirname");
    return check(Clun.$`echo -n -n hello`, 0, "hello", "", "echo repeated -n");
  })
  .then(() => check(Clun.$`echo -- -n hello`, 0, "-- -n hello\n", "", "echo ordinary flags"))
  .then(() => check(Clun.$`echo "\n"`, 0, "\\n\n", "", "echo quoted escape"))
  .then(() => check(Clun.$`echo ${"\n\n"}`, 0, "\n\n", "", "echo pure newlines"))
  .then(() => check(Clun.$`echo ${"\n\n\n"}`, 0, "\n\n", "", "echo newline cap"))
  .then(() => check(Clun.$`echo ${"a\n\n"}`, 0, "a\n", "", "echo mixed newline cap"))
  .then(() => {
    console.log("echo");
    return check(Clun.$`exit`, 0, "", "", "exit default");
  })
  .then(() => check(Clun.$`exit 11`, 11, "", "", "exit explicit"))
  .then(() => check(Clun.$`exit 62757836`, 204, "", "", "exit wraps"))
  .then(() => check(Clun.$`exit abc`, 1, "", "exit: numeric argument required\n", "exit numeric"))
  .then(() => check(Clun.$`exit 3 5`, 1, "", "exit: too many arguments\n", "exit arity"))
  .then(() => check(Clun.$`exit 2; echo unreachable`, 2, "", "", "exit terminates script"))
  .then(() => console.log("exit"));
