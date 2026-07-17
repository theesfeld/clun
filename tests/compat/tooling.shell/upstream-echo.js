function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function check(job, expectedOut, label) {
  return job.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    assert(stderr(result) === "", label + " stderr");
  });
}

let chain = Promise.resolve();

function queue(job, out, label) {
  chain = chain.then(() => check(job, out, label));
}

queue(Clun.$`echo`, "\n", "no arguments");
queue(Clun.$`echo hello`, "hello\n", "single argument");
queue(Clun.$`echo hello world`, "hello world\n", "multiple arguments");
queue(Clun.$`echo "hello world"`, "hello world\n", "quoted argument");
queue(Clun.$`echo hello   world`, "hello world\n", "collapsed spaces");
queue(Clun.$`echo ""`, "\n", "empty string");
queue(Clun.$`echo one two three four`, "one two three four\n", "many arguments");
queue(Clun.$`echo -n`, "", "no arguments without newline");
queue(Clun.$`echo -n hello`, "hello", "single argument without newline");
queue(Clun.$`echo -n hello world`, "hello world", "multiple arguments without newline");
queue(Clun.$`echo -n "hello world"`, "hello world", "quoted argument without newline");
queue(Clun.$`echo -n ""`, "", "empty string without newline");
queue(Clun.$`echo -n one two three`, "one two three", "many arguments without newline");
queue(Clun.$`echo -x`, "-x\n", "invalid flag");
queue(Clun.$`echo -abc`, "-abc\n", "invalid multi-character flag");
queue(Clun.$`echo --invalid`, "--invalid\n", "invalid long flag");
queue(Clun.$`echo -n -n hello`, "hello", "repeated no-newline flag");
queue(Clun.$`echo -- -n hello`, "-- -n hello\n", "double dash argument");
queue(Clun.$`echo "\n"`, "\\n\n", "literal backslash n");
queue(Clun.$`echo ${"\n\n"}`, "\n\n", "two-newline interpolation");
queue(Clun.$`echo ${"\n\n\n"}`, "\n\n", "three-newline interpolation");
queue(Clun.$`echo ${"a\n\n"}`, "a\n", "mixed trailing-newline interpolation");

chain.then(() => console.log("upstream-echo: 41 exact sites"));
