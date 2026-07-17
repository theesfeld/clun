function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function check(job, expectedCode, expectedOut, expectedErr, label, normalizeOutput) {
  return job.quiet().nothrow().then(result => {
    const actualOut = normalizeOutput ? words(result.text()) : result.text();
    const wantedOut = normalizeOutput ? words(expectedOut) : expectedOut;
    assert(result.exitCode === expectedCode, label + " exit code");
    assert(actualOut === wantedOut,
      label + " stdout " + JSON.stringify(actualOut) + " !== " + JSON.stringify(wantedOut));
    assert(stderr(result) === expectedErr, label + " stderr");
    return result;
  });
}

function words(text) {
  return text.split("\n").map(line => line.trim()).filter(line => line.length > 0).sort().join("|");
}

assert(words("b\na\n") === words("a\nb\n"), "source-normalized output order");

const root = "clun-shell-upstream-mv-rm.tmp";
let absoluteRoot = "";
let chain = Clun.$`pwd`.text().then(text => {
  absoluteRoot = text.trim() + "/" + root;
});

function queue(jobFactory, code, outFactory, err, label, normalizeOutput = false) {
  chain = chain.then(() => check(
    jobFactory(),
    code,
    typeof outFactory === "function" ? outFactory() : outFactory,
    err,
    label,
    normalizeOutput,
  ));
}

queue(() => Clun.$`rm -rf ${root}; mkdir -p ${root}`, 0, "", "", "root setup");

queue(() => Clun.$`mkdir -p mv1; echo foo > mv1/a; mv mv1/a mv1/b; cat mv1/b`.cwd(root),
  0, "foo\n", "", "move file to file");
queue(() => Clun.$`mkdir -p mv2/foo; touch mv2/a; mv mv2/a mv2/foo; ls mv2/foo`.cwd(root),
  0, "a\n", "", "move file into directory");
queue(() => Clun.$`mkdir -p mv3/d; echo -n file > mv3/a; echo -n file > mv3/b; echo -n file > mv3/c; mv mv3/a mv3/b mv3/c mv3/d; ls mv3/d`.cwd(root),
  0, "a\nb\nc\n", "", "move multiple files", true);
queue(() => Clun.$`mkdir -p mv4; echo -n hi > mv4/file1.txt; echo -n hello > mv4/file2.txt; mv mv4/file1.txt mv4/file2.txt mv4/does_not_exist/`.cwd(root),
  1, "", "mv: mv4/does_not_exist/: No such file or directory\n", "missing destination directory");
queue(() => Clun.$`mkdir -p mv5/foo mv5/bar; echo hi > mv5/foo/inside_foo; echo hi > mv5/bar/inside_bar; mv mv5/foo mv5/bar; ls -R mv5/bar`.cwd(root),
  0, "foo\ninside_bar\nmv5/bar/foo:\ninside_foo\n", "", "move directory into directory", true);
queue(() => Clun.$`mkdir -p mv6/foo; touch mv6/a; mv mv6/foo/ mv6/a`.cwd(root),
  20, "", "mv: mv6/a: Not a directory\n", "move directory onto file");

queue(() => Clun.$`mkdir -p rm1/node_modules/pkg; touch rm1/node_modules/pkg/file; rm -rf rm1/node_modules; ls -d rm1/node_modules`.cwd(root),
  1, "", "ls: rm1/node_modules: No such file or directory\n", "remove node_modules");

queue(() => Clun.$`mkdir -p rm2; touch rm2/existent.txt; rm -f rm2/non_existent.txt`.cwd(root),
  0, "", "", "force missing file");
queue(() => Clun.$`rm rm2/non_existent.txt`.cwd(root),
  1, "", "rm: rm2/non_existent.txt: No such file or directory\n", "missing file error");
queue(() => Clun.$`rm -v ${absoluteRoot + "/rm2/existent.txt"}`.cwd(root),
  0, () => absoluteRoot + "/rm2/existent.txt\n", "", "verbose file removal");

queue(() => Clun.$`mkdir -p rm3; touch rm3/existent.txt; rm -rv ${absoluteRoot + "/rm3/existent.txt"}`.cwd(root),
  0, () => absoluteRoot + "/rm3/existent.txt\n", "", "recursive file removal");
queue(() => Clun.$`mkdir -p rm3/folder/sub; echo -n test > rm3/folder/sub/file.txt; rm -rv ${absoluteRoot + "/rm3/folder"}`.cwd(root),
  0,
  () => absoluteRoot + "/rm3/folder/sub/file.txt\n" + absoluteRoot + "/rm3/folder/sub\n" +
    absoluteRoot + "/rm3/folder\n",
  "", "recursive directory removal", true);
queue(() => Clun.$`mkdir -p rm3cwd`.cwd(root), 0, "", "", "recursive cwd setup");
queue(() => Clun.$`mkdir -p foo/bar; touch foo/lol foo/nice foo/lmao foo/bar/great foo/bar/wow; rm -rfv foo/`.cwd(root + "/rm3cwd"),
  0, "foo/bar/great\nfoo/bar/wow\nfoo/bar\nfoo/lol\nfoo/nice\nfoo/lmao\nfoo/\n", "",
  "recursive cwd removal", true);

queue(() => Clun.$`mkdir -p rm4/sub_dir rm4/sub_dir_files; touch rm4/existent.txt rm4/sub_dir_files/file.txt; rm -d rm4/existent.txt`.cwd(root),
  0, "", "", "rm dir flag file");
queue(() => Clun.$`rm -d rm4/sub_dir`.cwd(root), 0, "", "", "rm empty directory");
queue(() => Clun.$`rm -d rm4/sub_dir_files`.cwd(root),
  1, "", "rm: rm4/sub_dir_files: Directory not empty\n", "rm nonempty directory");

queue(() => Clun.$`rm -rf ${root}`, 0, "", "", "root cleanup");
chain.then(() => console.log("upstream-mv-rm: 20 exact sites"));
