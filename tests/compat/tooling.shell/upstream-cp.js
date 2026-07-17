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

const root = "clun-shell-upstream-cp.tmp";
const repeated = Array(50).fill("c7/hello.txt");
let absoluteRoot = "";
let chain = Clun.$`pwd`.text().then(text => {
  absoluteRoot = text.trim() + "/" + root;
});

function queue(jobFactory, code, outFactory, err, label) {
  chain = chain.then(() => check(
    jobFactory(),
    code,
    typeof outFactory === "function" ? outFactory() : outFactory,
    err,
    label,
  ));
}

queue(() => Clun.$`rm -rf ${root}; mkdir -p ${root}`, 0, "", "", "root setup");

queue(() => Clun.$`mkdir -p c1; echo -n payload > c1/source; cp -v c1/source c1/dest`.cwd(root),
  0, () => absoluteRoot + "/c1/source -> " + absoluteRoot + "/c1/dest\n", "", "file to file");
queue(() => Clun.$`cat c1/dest`.cwd(root), 0, "payload", "", "file to file contents");

queue(() => Clun.$`mkdir -p c2; echo -n payload > c2/source; echo -n old > c2/dest; cp -v c2/source c2/dest`.cwd(root),
  0, () => absoluteRoot + "/c2/source -> " + absoluteRoot + "/c2/dest\n", "", "replace file");
queue(() => Clun.$`cat c2/dest`.cwd(root), 0, "payload", "", "replace contents");

queue(() => Clun.$`mkdir -p c3/dest; echo -n payload > c3/source; cp -v c3/source c3/dest`.cwd(root),
  0, () => absoluteRoot + "/c3/source -> " + absoluteRoot + "/c3/dest/source\n", "", "file to directory");
queue(() => Clun.$`cat c3/dest/source`.cwd(root), 0, "payload", "", "directory target contents");

queue(() => Clun.$`mkdir -p c4; echo -n payload > c4/source; cp -v c4/source c4/missing/`.cwd(root),
  1, "", "cp: c4/missing/ is not a directory\n", "missing directory");

queue(() => Clun.$`mkdir -p c5/dest; echo -n one > c5/one; echo -n two > c5/two; cp -v c5/one c5/two c5/dest`.cwd(root),
  0,
  () => absoluteRoot + "/c5/one -> " + absoluteRoot + "/c5/dest/one\n" +
    absoluteRoot + "/c5/two -> " + absoluteRoot + "/c5/dest/two\n",
  "", "multiple files");
queue(() => Clun.$`cat c5/dest/one c5/dest/two`.cwd(root), 0, "onetwo", "", "multiple contents");

queue(() => Clun.$`mkdir -p c6/one c6/two; cp -v c6/one c6/two c6/missing`.cwd(root),
  1, "", "cp: c6/one is a directory (not copied)\ncp: c6/two is a directory (not copied)\n",
  "directories without recursive");

queue(() => Clun.$`mkdir -p c7/dest; echo hi! > c7/hello.txt; cp ${repeated} c7/dest`.cwd(root),
  0, "", "", "repeated identical source");
queue(() => Clun.$`cat c7/dest/hello.txt`.cwd(root), 0, "hi!\n", "", "repeated source contents");

queue(() => Clun.$`mkdir -p c8; echo -n "Hello, World!" > c8/source; cp c8/source c8/copy`.cwd(root),
  0, "", "", "simple copy");
queue(() => Clun.$`cat c8/copy`.cwd(root), 0, "Hello, World!", "", "simple copy contents");

queue(() => Clun.$`mkdir -p c9; echo -n "Hello, World!" > c9/source; echo -n old > c9/existing; cp c9/source c9/existing`.cwd(root),
  0, "", "", "existing target");
queue(() => Clun.$`cat c9/existing`.cwd(root), 0, "Hello, World!", "", "existing target contents");

queue(() => Clun.$`mkdir -p c10/dest; echo -n "Hello, World!" > c10/source; cp c10/source c10/source c10/dest`.cwd(root),
  0, "", "", "duplicate sources");
queue(() => Clun.$`cat c10/dest/source`.cwd(root), 0, "Hello, World!", "", "duplicate source contents");

queue(() => Clun.$`mkdir -p c11; touch c11/a; cp c11/a c11/a`.cwd(root),
  1, "", "cp: c11/a and c11/a are identical (not copied)\n", "same file");

queue(() => Clun.$`mkdir -p c12; echo -n payload > c12/source; echo -n existing > c12/target; cp c12/source c12/source c12/target`.cwd(root),
  1, "", "cp: c12/target is not a directory\ncp: c12/target is not a directory\n",
  "multiple sources to file");

queue(() => Clun.$`mkdir -p c13/source; cp c13/source c13/copy`.cwd(root),
  1, "", "cp: c13/source is a directory (not copied)\n", "directory not recursive");

queue(() => Clun.$`mkdir -p c14/dest; echo -n hello > c14/one; echo -n world > c14/two; cp c14/one c14/two c14/dest`.cwd(root),
  0, "", "", "multiple source success");
queue(() => Clun.$`cat c14/dest/one c14/dest/two`.cwd(root), 0, "helloworld", "", "multiple source contents");

queue(() => Clun.$`mkdir -p c15/dest; echo -n hello > c15/one; echo -n world > c15/two; cp c15/one c15/two c15/dest && echo HI`.cwd(root),
  0, "HI\n", "", "copy then command");

queue(() => Clun.$`mkdir -p c16/source; echo -n "Hello, World!" > c16/source/file; cp -R c16/source c16/copy`.cwd(root),
  0, "", "", "recursive copy");
queue(() => Clun.$`cat c16/copy/file`.cwd(root), 0, "Hello, World!", "", "recursive contents");

queue(() => Clun.$`rm -rf ${root}`, 0, "", "", "root cleanup");
chain.then(() => console.log("upstream-cp: 32 exact sites"));
