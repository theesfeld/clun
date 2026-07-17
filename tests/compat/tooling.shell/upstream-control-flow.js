function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

const root = "clun-shell-upstream-control-flow.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}; touch ${root}/package.json`).quiet();

function queue(source, expectedOut, expectedCode, label, expectedErr = "") {
  chain = chain.then(() => job(source).cwd(root).quiet().nothrow()).then(
    result => {
      assert(result.exitCode === expectedCode, label + " exit code");
      assert(result.text() === expectedOut, label + " stdout");
      assert(stderr(result) === expectedErr, label + " stderr");
    },
    error => { throw new Error(label + ": " + error); },
  );
}

queue("if true | true; then echo yes; else echo no; fi", "yes\n", 0,
  "pipeline condition true");
queue("if false | false; then echo yes; else echo no; fi", "no\n", 0,
  "pipeline condition false");
queue("if echo test | true; then echo success; fi", "success\n", 0,
  "pipeline condition drains stdout");

queue("if\n echo cond;\nthen\n echo then;\nelif\n echo elif;\nthen\n echo elif then;\nelse\n echo else;\nfi",
  "cond\nthen\n", 0, "basic multiline");
queue("if\n echo cond\nthen\n echo then\nelif\n echo elif\nthen\n echo elif then\nelse\n echo else\nfi",
  "cond\nthen\n", 0, "basic multiline without semicolons");
queue("if echo hi; then echo hey; else echo no; fi | cat", "hi\nhey\n", 0,
  "if compound in pipeline");
queue("if echo hi; then echo lmao; fi && echo nice", "hi\nlmao\nnice\n", 0,
  "true if followed by and");
queue("if [[ -f package.json ]]; [[ -f missing ]]; then echo no; else echo okay; echo makes sense!; fi",
  "okay\nmakes sense!\n", 0, "multi statement branches");

for (const token of ["if", "else", "elif", "then", "fi"]) {
  queue(`echo lksdfjklsdjf${token}`, `lksdfjklsdjf${token}\n`, 0,
    token + " embedded suffix");
  queue(`echo hi ${token}`, `hi ${token}\n`, 0, token + " argument");
  queue(`echo ${token} hi`, `${token} hi\n`, 0, token + " first argument");
}
queue("echo fif hi", "fif hi\n", 0, "reserved word prefix");

const pathCases = [
  ["if echo foo; then echo bar; fi", "foo\nbar\n"],
  ["if ! echo foo; then echo bar; fi", "foo\n"],
  ["if echo foo; then echo bar; else echo baz; fi", "foo\nbar\n"],
  ["if ! echo foo; then echo bar; else echo baz; fi", "foo\nbaz\n"],
  ["if echo 1; then echo 2; elif echo 3; then echo 4; fi", "1\n2\n"],
  ["if ! echo 1; then echo 2; elif echo 3; then echo 4; fi", "1\n3\n4\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; fi", "1\n3\n"],
  ["if echo 1; then echo 2; elif echo 3; then echo 4; else echo 5; fi", "1\n2\n"],
  ["if ! echo 1; then echo 2; elif echo 3; then echo 4; else echo 5; fi", "1\n3\n4\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; else echo 5; fi", "1\n3\n5\n"],
  ["if echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; fi", "1\n2\n"],
  ["if ! echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; fi", "1\n3\n4\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif echo 5; then echo 6; fi", "1\n3\n5\n6\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif ! echo 5; then echo 6; fi", "1\n3\n5\n"],
  ["if echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi", "1\n2\n"],
  ["if ! echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi", "1\n3\n4\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi", "1\n3\n5\n6\n"],
  ["if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif ! echo 5; then echo 6; else echo 7; fi", "1\n3\n5\n7\n"],
];
pathCases.forEach((entry, index) => queue(entry[0], entry[1], 0, "branch path " + index));

const statusCases = [
  ["if (exit 0); then (exit 0); fi", 0],
  ["if (exit 0); then (exit 1); fi", 1],
  ["if (exit 1); then (exit 2); fi", 0],
  ["if (exit 0); then (exit 0); else (exit 1); fi", 0],
  ["if (exit 0); then (exit 1); else (exit 2); fi", 1],
  ["if (exit 1); then (exit 2); else (exit 0); fi", 0],
  ["if (exit 1); then (exit 0); else (exit 2); fi", 2],
  ["if (exit 0); then (exit 0); elif (exit 1); then (exit 2); fi", 0],
  ["if (exit 0); then (exit 1); elif (exit 2); then (exit 3); fi", 1],
  ["if (exit 1); then (exit 2); elif (exit 0); then (exit 0); fi", 0],
  ["if (exit 1); then (exit 2); elif (exit 0); then (exit 3); fi", 3],
  ["if (exit 0); then (exit 0); elif (exit 1); then (exit 2); elif (exit 3); then (exit 4); else (exit 5); fi", 0],
  ["if (exit 0); then (exit 11); elif (exit 1); then (exit 2); elif (exit 3); then (exit 4); else (exit 5); fi", 11],
  ["if (exit 1); then (exit 2); elif (exit 0); then (exit 0); elif (exit 3); then (exit 4); else (exit 5); fi", 0],
  ["if (exit 1); then (exit 2); elif (exit 0); then (exit 13); elif (exit 3); then (exit 4); else (exit 5); fi", 13],
  ["if (exit 1); then (exit 2); elif (exit 3); then (exit 4); elif (exit 0); then (exit 0); else (exit 5); fi", 0],
  ["if (exit 1); then (exit 2); elif (exit 3); then (exit 4); elif (exit 0); then (exit 5); else (exit 6); fi", 5],
  ["if (exit 1); then (exit 2); elif (exit 3); then (exit 4); elif (exit 5); then (exit 6); else (exit 0); fi", 0],
  ["if (exit 1); then (exit 2); elif (exit 3); then (exit 4); elif (exit 5); then (exit 6); else (exit 7); fi", 7],
];
statusCases.forEach((entry, index) => queue(entry[0], "", entry[1], "branch status " + index));

const linebreakCases = [
  "if\necho foo;then echo bar;fi",
  "if echo foo\nthen echo bar;fi",
  "if echo foo;then\necho bar;fi",
  "if echo foo;then echo bar\nfi",
];
linebreakCases.forEach((source, index) => queue(source, "foo\nbar\n", 0,
  "basic linebreak " + index));

const falseLinebreakCases = [
  "if ! echo foo;then echo bar\nelif echo baz;then echo qux;fi",
  "if ! echo foo;then echo bar;elif\necho baz;then echo qux;fi",
  "if ! echo foo;then echo bar;elif echo baz\nthen echo qux;fi",
  "if ! echo foo;then echo bar;elif echo baz;then\necho qux;fi",
];
falseLinebreakCases.forEach((source, index) => queue(source, "foo\nbaz\nqux\n", 0,
  "elif linebreak " + index));
queue("if ! echo foo;then echo bar\nelse echo baz;fi", "foo\nbaz\n", 0,
  "linebreak before else");
queue("if ! echo foo;then echo bar;else\necho baz;fi", "foo\nbaz\n", 0,
  "linebreak after else");
queue("if ! echo foo;then echo bar;else echo baz\nfi", "foo\nbaz\n", 0,
  "linebreak before fi");

queue("if echo 1; echo 2\necho 3; ! echo 4; then echo x1; echo x2\necho x3; echo x4; elif echo 5; echo 6\necho 7; echo 8; then echo 9; echo 10\necho 11; echo 12; else echo x5; echo x6\necho x7; echo x8; fi",
  "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", 0,
  "multiple commands per branch");
queue("if echo foo\nthen echo bar\nelse echo baz\nfi >redir_out\ncat redir_out",
  "foo\nbar\n", 0, "compound redirection");

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-control-flow: 124 exact sites"));
