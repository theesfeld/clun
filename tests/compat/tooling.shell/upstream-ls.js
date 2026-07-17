function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function lines(text) {
  return text.split("\n").map(line => line.trim()).filter(line => line.length > 0).sort();
}

function sameLines(actual, expected, label) {
  const got = lines(actual).join("|");
  const want = expected.slice().sort().join("|");
  assert(got === want, label + " lines");
}

const root = "clun-shell-upstream-ls.tmp";
let chain = Promise.resolve();

function inspect(jobFactory, label, callback) {
  chain = chain.then(() => jobFactory().quiet().nothrow().then(result => callback(result, label)));
}

function success(jobFactory, expected, label) {
  inspect(jobFactory, label, (result, name) => {
    assert(result.exitCode === 0, name + " exit code");
    assert(result.text() === expected, name + " stdout");
    assert(stderr(result) === "", name + " stderr");
  });
}

success(() => Clun.$`rm -rf ${root}; mkdir -p ${root}`, "", "root setup");

success(() => Clun.$`mkdir -p nm/node_modules/pkg/sub; touch nm/node_modules/pkg/index.js nm/node_modules/pkg/sub/file`.cwd(root),
  "", "node_modules setup");
inspect(() => Clun.$`ls -RA .`.cwd(root + "/nm/node_modules"), "node_modules recursive", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  const output = result.text();
  assert(output.includes("pkg"), name + " package");
  assert(output.includes("index.js"), name + " file");
  assert(output.includes("sub"), name + " subdirectory");
});

success(() => Clun.$`mkdir -p basic/foo; touch basic/a basic/b basic/c basic/foo/a basic/foo/b basic/foo/c`.cwd(root),
  "", "basic setup");
inspect(() => Clun.$`ls -RA .`.cwd(root + "/basic"), "recursive basic", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), ["./foo:", "a", "a", "b", "b", "c", "c", "foo"], name);
});
success(() => Clun.$`ls`.cwd(root + "/basic"), "a\nb\nc\nfoo\n", "no arguments");

success(() => Clun.$`mkdir -p all/.hidden-dir; touch all/.hidden all/regular`.cwd(root), "", "all setup");
inspect(() => Clun.$`ls -a`.cwd(root + "/all"), "show all", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), [".", "..", ".hidden", ".hidden-dir", "regular"], name);
});
inspect(() => Clun.$`ls -A`.cwd(root + "/all"), "almost all", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), [".hidden", ".hidden-dir", "regular"], name);
});
success(() => Clun.$`ls -d foo`.cwd(root + "/basic"), "foo\n", "directory itself");

success(() => Clun.$`ls a b c`.cwd(root + "/basic"), "a\nb\nc\n", "multiple files");
success(() => Clun.$`mkdir -p multi/dir1 multi/dir2; touch multi/dir1/file1 multi/dir2/file2`.cwd(root),
  "", "multiple directories setup");
inspect(() => Clun.$`ls dir1 dir2`.cwd(root + "/multi"), "multiple directories", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), ["dir1:", "dir2:", "file1", "file2"], name);
});
inspect(() => Clun.$`ls a foo`.cwd(root + "/basic"), "mixed arguments", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), ["a", "foo:", "a", "b", "c"], name);
});

success(() => Clun.$`mkdir -p empty/dir`.cwd(root), "", "empty setup");
success(() => Clun.$`ls dir`.cwd(root + "/empty"), "", "empty directory");
success(() => Clun.$`mkdir -p hidden/only; touch hidden/only/.hidden1 hidden/only/.hidden2`.cwd(root),
  "", "hidden setup");
inspect(() => Clun.$`ls -a only`.cwd(root + "/hidden"), "hidden only", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), [".", "..", ".hidden1", ".hidden2"], name);
});

const longName = "a".repeat(100);
success(() => Clun.$`mkdir -p names; touch names/${longName}; touch names/"file with spaces"; touch names/"file-with-!@#$%^&*()"`.cwd(root),
  "", "names setup");
inspect(() => Clun.$`ls`.cwd(root + "/names"), "long and special names", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  const output = lines(result.text());
  assert(output.includes(longName), name + " long name");
  assert(output.includes("file with spaces"), name + " spaces");
  assert(output.includes("file-with-!@#$%^&*()"), name + " special characters");
});

success(() => Clun.$`mkdir -p flags/sub; touch flags/.hidden flags/sub/.hidden-sub`.cwd(root),
  "", "flags setup");
inspect(() => Clun.$`ls -Ra`.cwd(root + "/flags"), "recursive all", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  assert(result.text().includes(".hidden\n"), name + " root hidden");
  assert(result.text().includes(".hidden-sub\n"), name + " nested hidden");
});
inspect(() => Clun.$`ls -RA`.cwd(root + "/flags"), "recursive almost all", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  assert(result.text().includes(".hidden\n"), name + " root hidden");
  assert(result.text().includes(".hidden-sub\n"), name + " nested hidden");
  assert(!lines(result.text()).includes("."), name + " excludes dot");
  assert(!lines(result.text()).includes(".."), name + " excludes dotdot");
});
success(() => Clun.$`mkdir -p dmulti/dir1 dmulti/dir2`.cwd(root), "", "directory list setup");
success(() => Clun.$`ls -d dir1 dir2`.cwd(root + "/dmulti"), "dir1\ndir2\n", "multiple directory selves");

inspect(() => Clun.$`ls lskdjflksdjf`.cwd(root), "single missing", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(result.text() === "", name + " stdout");
  assert(stderr(result) === "ls: lskdjflksdjf: No such file or directory\n", name + " stderr");
});
inspect(() => Clun.$`ls nonexistent1 nonexistent2`.cwd(root), "multiple missing", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(stderr(result).includes("nonexistent1: No such file or directory"), name + " first");
  assert(stderr(result).includes("nonexistent2: No such file or directory"), name + " second");
});
success(() => Clun.$`mkdir -p mixed; touch mixed/a`.cwd(root), "", "mixed error setup");
inspect(() => Clun.$`ls a nonexistent`.cwd(root + "/mixed"), "mixed missing", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(result.text() === "a\n", name + " partial stdout");
  assert(stderr(result).includes("nonexistent: No such file or directory"), name + " stderr");
});
inspect(() => Clun.$`ls -z`.cwd(root), "invalid flag", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(stderr(result).includes("illegal option"), name + " stderr");
});
inspect(() => Clun.$`ls -az`.cwd(root), "invalid combined flags", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(stderr(result).includes("illegal option"), name + " stderr");
});

// Exact stable+engineering ls.test.ts L274 / L285 (chmod 000 permission sites).
// Non-root runners only: chmod 000 must deny readdir. Always restore modes in cleanup.
success(() => Clun.$`mkdir -p perm/restricted`.cwd(root), "", "permission setup");
inspect(() => Clun.$`chmod 000 restricted; ls restricted; status=$?; chmod 755 restricted; exit $status`.cwd(root + "/perm"),
  "permission denied directory", (result, name) => {
    assert(result.exitCode === 1, name + " exit code");
    assert(result.text() === "", name + " stdout empty");
    assert(stderr(result).includes("Permission denied"), name + " stderr");
  });

success(() => Clun.$`mkdir -p perm-rec/level1/level2/level3; touch perm-rec/level1/file1 perm-rec/level1/file2 perm-rec/level1/file3; touch perm-rec/level1/level2/file4 perm-rec/level1/level2/file5 perm-rec/level1/level2/file6; touch perm-rec/level1/level2/level3/file7 perm-rec/level1/level2/level3/file8 perm-rec/level1/level2/level3/file9`.cwd(root),
  "", "permission recursive setup");
inspect(() => Clun.$`chmod 000 level1/level2; ls -R level1; status=$?; chmod 755 level1/level2; exit $status`.cwd(root + "/perm-rec"),
  "permission denied directory recursive", (result, name) => {
    assert(result.exitCode === 1, name + " exit code");
    const output = lines(result.text());
    assert(output.includes("file1"), name + " lists file1");
    assert(output.includes("file2"), name + " lists file2");
    assert(output.includes("file3"), name + " lists file3");
    assert(stderr(result).includes("Permission denied"), name + " stderr");
  });

success(() => Clun.$`mkdir -p broken; touch broken/will-remove; ln -s will-remove broken/broken-file; rm broken/will-remove; mkdir broken/will-remove-dir; ln -s will-remove-dir broken/broken-dir; rm -rf broken/will-remove-dir`.cwd(root),
  "", "broken symlink setup");
inspect(() => Clun.$`ls broken-file`.cwd(root + "/broken"), "broken file symlink", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(stderr(result) === "ls: broken-file: No such file or directory\n", name + " stderr");
});
inspect(() => Clun.$`ls broken-dir`.cwd(root + "/broken"), "broken directory symlink", (result, name) => {
  assert(result.exitCode === 1, name + " exit code");
  assert(stderr(result) === "ls: broken-dir: No such file or directory\n", name + " stderr");
});
success(() => Clun.$`mkdir -p broken-rec/foo; touch broken-rec/foo/a broken-rec/foo/b broken-rec/foo/c; mkdir broken-rec/foo/will-remove; ln -s will-remove broken-rec/foo/broken-link; rm -rf broken-rec/foo/will-remove`.cwd(root),
  "", "broken recursive setup");
inspect(() => Clun.$`ls -RA .`.cwd(root + "/broken-rec"), "broken recursive symlink", (result, name) => {
  assert(result.exitCode === 0, name + " exit code");
  sameLines(result.text(), ["./foo:", "a", "b", "broken-link", "c", "foo"], name);
});

success(() => Clun.$`rm -rf ${root}`, "", "root cleanup");
chain.then(() => console.log("upstream-ls: 54 exact sites"));
