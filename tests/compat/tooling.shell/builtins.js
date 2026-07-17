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
  .then(() => {
    console.log("exit");
    return check(Clun.$`seq`, 1, "", "usage: seq [-w] [-f format] [-s string] [-t string] [first [incr]] last\n", "seq usage");
  })
  .then(() => check(Clun.$`seq -s`, 1, "", "seq: option requires an argument -- s\n", "seq missing separator"))
  .then(() => check(Clun.$`seq 0 5`, 0, "0\n1\n2\n3\n4\n5\n", "", "seq ascending"))
  .then(() => check(Clun.$`seq 5 0`, 0, "5\n4\n3\n2\n1\n0\n", "", "seq descending"))
  .then(() => check(Clun.$`seq -s. -t, 0 5`, 0, "0.1.2.3.4.5.,", "", "seq separators"))
  .then(() => check(Clun.$`seq 0`, 0, "1\n0\n", "", "seq single zero"))
  .then(() => check(Clun.$`seq 4 0 7`, 1, "", "seq: zero increment\n", "seq zero increment"))
  .then(() => check(Clun.$`seq 4 -2 7`, 1, "", "seq: needs positive increment\n", "seq direction"))
  .then(() => check(Clun.$`seq 16777216 16777218`, 0, "16777216\n", "", "seq f32 non-advance"))
  .then(() => check(Clun.$`seq 1 0.00000001 2`, 0, "1\n", "", "seq tiny increment"))
  .then(() => check(Clun.$`seq -w -s, 8 2 12`, 0, "08,10,12,", "", "seq fixed width"))
  .then(() => check(Clun.$`seq -f %05.1f -s, 1 1 3`, 0, "001.0,002.0,003.0,", "", "seq format"))
  .then(() => {
    console.log("seq");
    return check(Clun.$`rm -rf clun-shell-builtins.tmp`, 0, "", "", "filesystem setup");
  })
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/nested`, 0, "", "", "mkdir parents"))
  .then(() => check(Clun.$`touch clun-shell-builtins.tmp/one clun-shell-builtins.tmp/two`, 0, "", "", "touch files"))
  .then(() => check(Clun.$`printf alpha > clun-shell-builtins.tmp/one`, 0, "", "", "write first"))
  .then(() => check(Clun.$`printf beta > clun-shell-builtins.tmp/two`, 0, "", "", "write second"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/one clun-shell-builtins.tmp/two`, 0, "alphabeta", "", "cat files"))
  .then(() => check(Clun.$`printf "a\n\nb\n" | cat -n`, 0, "     1\ta\n     2\t\n     3\tb\n", "", "cat stdin numbering"))
  .then(() => check(Clun.$`printf "a\n\n\nb\n" | cat -s`, 0, "a\n\nb\n", "", "cat squeeze"))
  .then(() => check(
    Clun.$`cat clun-shell-builtins.tmp/one clun-shell-builtins.tmp/missing`,
    1,
    "alpha",
    "cat: clun-shell-builtins.tmp/missing: No such file or directory\n",
    "cat partial error",
  ))
  .then(() => check(Clun.$`touch -c clun-shell-builtins.tmp/not-created`, 0, "", "", "touch no-create"))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/remove/a`, 0, "", "", "rm tree setup"))
  .then(() => check(Clun.$`touch clun-shell-builtins.tmp/remove/a/file`, 0, "", "", "rm file setup"))
  .then(() => check(
    Clun.$`rm -rv clun-shell-builtins.tmp/remove`,
    0,
    "clun-shell-builtins.tmp/remove/a/file\nclun-shell-builtins.tmp/remove/a\nclun-shell-builtins.tmp/remove\n",
    "",
    "rm recursive verbose",
  ))
  .then(() => check(Clun.$`rm -f clun-shell-builtins.tmp/missing`, 0, "", "", "rm force missing"))
  .then(() => check(
    Clun.$`rm clun-shell-builtins.tmp/missing`,
    1,
    "",
    "rm: clun-shell-builtins.tmp/missing: No such file or directory\n",
    "rm missing",
  ))
  .then(() => check(Clun.$`mkdir clun-shell-builtins.tmp/empty`, 0, "", "", "rm empty setup"))
  .then(() => check(Clun.$`rm -d clun-shell-builtins.tmp/empty`, 0, "", "", "rm empty directory"))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/victim`, 0, "", "", "rm symlink setup"))
  .then(() => check(Clun.$`printf important > clun-shell-builtins.tmp/victim/keep`, 0, "", "", "rm victim setup"))
  .then(() => check(Clun.$`ln -s victim clun-shell-builtins.tmp/link`, 0, "", "", "rm link setup"))
  .then(() => check(Clun.$`rm -rf clun-shell-builtins.tmp/link`, 0, "", "", "rm symlink"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/victim/keep`, 0, "important", "", "rm does not follow symlink"))
  .then(() => check(Clun.$`rm -rf /`, 1, "", "rm: \"/\" may not be removed\n", "rm root guard"))
  .then(() => check(Clun.$`rm -rf clun-shell-builtins.tmp`, 0, "", "", "filesystem cleanup"))
  .then(() => {
    console.log("filesystem-builtins");
    console.log("rm");
  });
