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
    const buffer = Buffer.alloc(10);
    return check(Clun.$`yes > ${buffer}`, 0, "", "", "yes default")
      .then(() => assert(buffer.toString() === "y\ny\ny\ny\ny\n", "yes default buffer"));
  })
  .then(() => {
    const buffer = Buffer.alloc(18);
    return check(Clun.$`yes xy > ${buffer}`, 0, "", "", "yes one argument")
      .then(() => assert(
        buffer.toString() === "xy\nxy\nxy\nxy\nxy\nxy\n",
        "yes one argument buffer",
      ));
  })
  .then(() => {
    const buffer = Buffer.alloc(17);
    return check(Clun.$`yes ab cd ef > ${buffer}`, 0, "", "", "yes multiple arguments")
      .then(() => assert(
        buffer.toString() === "ab cd ef\nab cd ef",
        "yes multiple arguments buffer",
      ));
  })
  .then(() => {
    const backing = Buffer.from("........");
    const view = backing.subarray(2, 6);
    return check(Clun.$`yes q > ${view}`, 0, "", "", "yes typed-array view")
      .then(() => assert(backing.toString() === "..q\nq\n..", "yes typed-array view offset"));
  })
  .then(() => check(
    Clun.$`yes`,
    1,
    "",
    "yes: unbounded output requires a streaming sink\n",
    "yes unbounded boundary",
  ))
  .then(() => check(
    Clun.$`yes xy | head -c 7`,
    0,
    "xy\nxy\nx",
    "",
    "yes pipeline streaming",
  ))
  .then(() => check(Clun.$`true | false`, 1, "", "", "builtin pipeline last failure"))
  .then(() => check(Clun.$`false | true`, 0, "", "", "builtin pipeline last success"))
  .then(() => check(
    Clun.$`exit 42 | echo after; echo outside`,
    0,
    "after\noutside\n",
    "",
    "pipeline exit isolation",
  ))
  .then(() => Clun.$`pwd`.text())
  .then(original => Clun.$`cd / | pwd`.text().then(actual => {
    assert(actual === original, "pipeline cwd isolation");
  }))
  .then(() => check(
    Clun.$`export CLUN_PIPE_VALUE=inner | echo $CLUN_PIPE_VALUE`,
    0,
    "\n",
    "",
    "pipeline environment isolation",
  ))
  .then(() => check(Clun.$`yes | true`, 0, "", "", "yes immediate success sink"))
  .then(() => check(Clun.$`yes | false`, 1, "", "", "yes immediate failure sink"))
  .then(() => check(
    Clun.$`true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false | true | false`,
    1,
    "",
    "",
    "builtin pipeline depth",
  ))
  .then(() => {
    console.log("yes");
    console.log("builtin-pipelines");
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
  .then(() => check(Clun.$`mv`, 1, "", "usage: mv [-f | -i | -n] [-hv] source target\n       mv [-f | -i | -n] [-v] source ... directory\n", "mv usage"))
  .then(() => check(Clun.$`mv --help`, 1, "", "mv: illegal option -- -\n", "mv illegal option"))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/move/dest`, 0, "", "", "mv setup"))
  .then(() => check(Clun.$`printf moved > clun-shell-builtins.tmp/move/a`, 0, "", "", "mv file setup"))
  .then(() => check(
    Clun.$`mv -v clun-shell-builtins.tmp/move/a clun-shell-builtins.tmp/move/b`,
    0,
    "clun-shell-builtins.tmp/move/a -> clun-shell-builtins.tmp/move/b\n",
    "",
    "mv file to file",
  ))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/move/b`, 0, "moved", "", "mv file result"))
  .then(() => check(Clun.$`printf one > clun-shell-builtins.tmp/move/one`, 0, "", "", "mv multi first"))
  .then(() => check(Clun.$`printf two > clun-shell-builtins.tmp/move/two`, 0, "", "", "mv multi second"))
  .then(() => check(
    Clun.$`mv clun-shell-builtins.tmp/move/one clun-shell-builtins.tmp/move/two clun-shell-builtins.tmp/move/dest`,
    0,
    "",
    "",
    "mv multiple into directory",
  ))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/move/dest/one clun-shell-builtins.tmp/move/dest/two`, 0, "onetwo", "", "mv multiple results"))
  .then(() => check(Clun.$`printf preserve > clun-shell-builtins.tmp/move/dest/no-overwrite`, 0, "", "", "mv no-overwrite target"))
  .then(() => check(Clun.$`printf replacement > clun-shell-builtins.tmp/move/no-overwrite`, 0, "", "", "mv no-overwrite source"))
  .then(() => check(Clun.$`mv -n clun-shell-builtins.tmp/move/no-overwrite clun-shell-builtins.tmp/move/dest`, 0, "", "", "mv no-overwrite"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/move/dest/no-overwrite clun-shell-builtins.tmp/move/no-overwrite`, 0, "preservereplacement", "", "mv no-overwrite results"))
  .then(() => check(
    Clun.$`mv clun-shell-builtins.tmp/move/b clun-shell-builtins.tmp/move/no-overwrite clun-shell-builtins.tmp/move/missing`,
    1,
    "",
    "mv: clun-shell-builtins.tmp/move/missing: No such file or directory\n",
    "mv missing multiple target",
  ))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/move/tree/sub clun-shell-builtins.tmp/move/outer`, 0, "", "", "mv directory setup"))
  .then(() => check(Clun.$`printf nested > clun-shell-builtins.tmp/move/tree/sub/file`, 0, "", "", "mv directory file"))
  .then(() => check(Clun.$`mv clun-shell-builtins.tmp/move/tree clun-shell-builtins.tmp/move/outer`, 0, "", "", "mv directory into directory"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/move/outer/tree/sub/file`, 0, "nested", "", "mv directory result"))
  .then(() => check(Clun.$`mkdir clun-shell-builtins.tmp/move/dir-fail`, 0, "", "", "mv directory failure setup"))
  .then(() => check(Clun.$`touch clun-shell-builtins.tmp/move/file-target`, 0, "", "", "mv file target setup"))
  .then(() => check(
    Clun.$`mv clun-shell-builtins.tmp/move/dir-fail/ clun-shell-builtins.tmp/move/file-target`,
    20,
    "",
    "mv: clun-shell-builtins.tmp/move/file-target: Not a directory\n",
    "mv directory onto file",
  ))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/list/foo/sub`, 0, "", "", "ls setup"))
  .then(() => check(Clun.$`touch clun-shell-builtins.tmp/list/a clun-shell-builtins.tmp/list/b clun-shell-builtins.tmp/list/.hidden clun-shell-builtins.tmp/list/foo/c clun-shell-builtins.tmp/list/foo/.secret clun-shell-builtins.tmp/list/foo/sub/d`, 0, "", "", "ls files"))
  .then(() => check(Clun.$`ls clun-shell-builtins.tmp/list`, 0, "a\nb\nfoo\n", "", "ls directory"))
  .then(() => Clun.$`ls -l clun-shell-builtins.tmp/list/a`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "ls long exit code");
    assert(stderr(result) === "", "ls long stderr");
    assert(
      /^-[rwxSsTt-]{9}\s+\d+\s+\d+\s+\d+\s+\d+\s+[A-Z][a-z]{2} \d{2} (?:\d{2}:\d{2}| \d{4}) clun-shell-builtins\.tmp\/list\/a\n$/.test(result.text()),
      "ls long metadata",
    );
  }))
  .then(() => check(Clun.$`ls -a clun-shell-builtins.tmp/list`, 0, ".\n..\n.hidden\na\nb\nfoo\n", "", "ls all"))
  .then(() => check(Clun.$`ls -A clun-shell-builtins.tmp/list`, 0, ".hidden\na\nb\nfoo\n", "", "ls almost all"))
  .then(() => check(Clun.$`ls -d clun-shell-builtins.tmp/list/foo`, 0, "clun-shell-builtins.tmp/list/foo\n", "", "ls directory itself"))
  .then(() => check(Clun.$`ls clun-shell-builtins.tmp/list/a clun-shell-builtins.tmp/list/b`, 0, "clun-shell-builtins.tmp/list/a\nclun-shell-builtins.tmp/list/b\n", "", "ls multiple files"))
  .then(() => check(
    Clun.$`ls -R clun-shell-builtins.tmp/list`,
    0,
    "a\nb\nfoo\nclun-shell-builtins.tmp/list/foo:\nc\nsub\nclun-shell-builtins.tmp/list/foo/sub:\nd\n",
    "",
    "ls recursive",
  ))
  .then(() => check(
    Clun.$`ls clun-shell-builtins.tmp/list/a clun-shell-builtins.tmp/list/missing`,
    1,
    "clun-shell-builtins.tmp/list/a\n",
    "ls: clun-shell-builtins.tmp/list/missing: No such file or directory\n",
    "ls partial error",
  ))
  .then(() => check(Clun.$`ls -az`, 1, "", "ls: illegal option -- z\n", "ls illegal option"))
  .then(() => check(Clun.$`ls ${""}`, 1, "", "ls: : No such file or directory\n", "ls empty path"))
  .then(() => check(Clun.$`ln -s nowhere clun-shell-builtins.tmp/list/broken`, 0, "", "", "ls broken link setup"))
  .then(() => check(
    Clun.$`ls clun-shell-builtins.tmp/list/broken`,
    1,
    "",
    "ls: clun-shell-builtins.tmp/list/broken: No such file or directory\n",
    "ls broken link",
  ))
  .then(() => check(Clun.$`cp`, 1, "", "usage: cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file target_file\n       cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file ... target_directory\n", "cp usage"))
  .then(() => check(Clun.$`cp -f a b`, 1, "", "cp: unsupported option, please open a GitHub issue -- -f\n", "cp unsupported"))
  .then(() => check(Clun.$`mkdir -p clun-shell-builtins.tmp/copy/dest clun-shell-builtins.tmp/copy/tree/sub`, 0, "", "", "cp setup"))
  .then(() => check(Clun.$`printf payload > clun-shell-builtins.tmp/copy/source`, 0, "", "", "cp source"))
  .then(() => Clun.$`cp -v clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/result`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "cp verbose exit code");
    assert(stderr(result) === "", "cp verbose stderr");
    const paths = result.text().trim().split(" -> ");
    assert(paths.length === 2, "cp verbose separator");
    assert(paths[0].endsWith("/clun-shell-builtins.tmp/copy/source"), "cp verbose source");
    assert(paths[1].endsWith("/clun-shell-builtins.tmp/copy/result"), "cp verbose destination");
  }))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/copy/result`, 0, "payload", "", "cp file result"))
  .then(() => check(Clun.$`cp clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/dest`, 0, "", "", "cp file into directory"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/copy/dest/source`, 0, "payload", "", "cp directory target result"))
  .then(() => check(
    Clun.$`cp clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/missing/`,
    1,
    "",
    "cp: clun-shell-builtins.tmp/copy/missing/ is not a directory\n",
    "cp trailing missing directory",
  ))
  .then(() => check(Clun.$`printf second > clun-shell-builtins.tmp/copy/second`, 0, "", "", "cp second source"))
  .then(() => check(Clun.$`cp clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/second clun-shell-builtins.tmp/copy/dest`, 0, "", "", "cp multiple files"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/copy/dest/source clun-shell-builtins.tmp/copy/dest/second`, 0, "payloadsecond", "", "cp multiple results"))
  .then(() => check(
    Clun.$`cp clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/source`,
    1,
    "",
    "cp: clun-shell-builtins.tmp/copy/source and clun-shell-builtins.tmp/copy/source are identical (not copied)\n",
    "cp identical",
  ))
  .then(() => check(Clun.$`printf nested > clun-shell-builtins.tmp/copy/tree/sub/file`, 0, "", "", "cp recursive file"))
  .then(() => check(Clun.$`cp -R clun-shell-builtins.tmp/copy/tree clun-shell-builtins.tmp/copy/tree-copy`, 0, "", "", "cp recursive"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/copy/tree-copy/sub/file`, 0, "nested", "", "cp recursive result"))
  .then(() => check(Clun.$`printf preserve > clun-shell-builtins.tmp/copy/preserved`, 0, "", "", "cp no-overwrite target"))
  .then(() => check(Clun.$`cp -n clun-shell-builtins.tmp/copy/source clun-shell-builtins.tmp/copy/preserved`, 0, "", "", "cp no-overwrite"))
  .then(() => check(Clun.$`cat clun-shell-builtins.tmp/copy/preserved`, 0, "preserve", "", "cp no-overwrite result"))
  .then(() => check(Clun.$`ln -s source clun-shell-builtins.tmp/copy/source-link`, 0, "", "", "cp symlink setup"))
  .then(() => check(Clun.$`cp clun-shell-builtins.tmp/copy/source-link clun-shell-builtins.tmp/copy/copied-link`, 0, "", "", "cp symlink"))
  .then(() => check(Clun.$`readlink clun-shell-builtins.tmp/copy/copied-link`, 0, "source\n", "", "cp symlink preserved"))
  .then(() => check(Clun.$`rm -rf clun-shell-builtins.tmp`, 0, "", "", "filesystem cleanup"))
  .then(() => {
    console.log("filesystem-builtins");
    console.log("rm");
    console.log("mv");
    console.log("ls");
    console.log("cp");
  });
