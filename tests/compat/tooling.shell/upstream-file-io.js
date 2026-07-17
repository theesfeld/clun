function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

const root = "clun-shell-upstream-file-io.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

function queue(source, expectedOut, expectedCode, label, expectedErr) {
  chain = chain.then(() => job(source).cwd(root).quiet().nothrow()).then(result => {
    assert(result.exitCode === expectedCode, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    if (expectedErr !== undefined) {
      assert(stderr(result).includes(expectedErr), label + " stderr");
    } else {
      assert(stderr(result) === "", label + " unexpected stderr");
    }
  });
}

function queueFile(source, path, expected, label) {
  queue(source, "", 0, label + " command");
  queue(`cat ${path}`, expected, 0, label + " file");
}

queueFile('echo "hello world" > output.txt', "output.txt", "hello world\n",
  "simple echo to file");
queueFile('echo -n "" > empty.txt', "empty.txt", "", "empty output to file");
queueFile('echo "" > zero.txt', "zero.txt", "\n", "zero-length write");

const largeX = "x".repeat(1024 * 10);
queueFile("echo -n " + largeX + " > large.txt", "large.txt", largeX,
  "large single write");
queueFile('mkdir -p subdir && echo "test" > subdir/file.txt', "subdir/file.txt", "test\n",
  "write to subdirectory");

queue('echo "should fail" > /dev/null/invalid/path', "", 1,
  "write through non-directory", "directory");
queue('echo "should fail" > nonexistent/file.txt', "", 1,
  "write to missing directory", "No such file or directory");
queue('echo "disappear" > /dev/null', "", 0, "write to dev null");

queueFile('echo "single" > single_writer.txt', "single_writer.txt", "single\n",
  "single writer completion");
queueFile('echo "robust test" > robust.txt', "robust.txt", "robust test\n",
  "writer lifetime");
queueFile('echo "captured content" > capture.txt', "capture.txt", "captured content\n",
  "capture during file write");

const largeA = "A".repeat(2 * 1024);
queueFile("echo -n " + largeA + " > atomic.txt", "atomic.txt", largeA,
  "atomic file write");
queueFile('echo "synchronous" > sync_write.txt', "sync_write.txt", "synchronous\n",
  "synchronous file write");
queue('echo "error test" > nonexistent_dir/file.txt', "", 1,
  "write error propagation", "No such file or directory");

queueFile('echo "new file" > new_file.txt', "new_file.txt", "new file\n",
  "default file creation");
queueFile('echo "original" > overwrite.txt && echo "short" > overwrite.txt', "overwrite.txt",
  "short\n", "overwrite truncates");
queueFile('echo "line1" > append.txt && echo "line2" >> append.txt && echo "line3" >> append.txt',
  "append.txt", "line1\nline2\nline3\n", "append preserves content");

queueFile('echo "builder test" > builder.txt', "builder.txt", "builder test\n",
  "builder file output");
queueFile('printf "no newline" > no_newline.txt', "no_newline.txt", "no newline",
  "output without newline");
queueFile('echo "first" > multi.txt && echo "second" >> multi.txt', "multi.txt",
  "first\nsecond\n", "write then append");
queueFile('echo "test with spaces in filename" > "file with spaces.txt"',
  '"file with spaces.txt"', "test with spaces in filename\n", "quoted redirect target");
queueFile('echo "pipe test" | cat > pipe_output.txt', "pipe_output.txt", "pipe test\n",
  "pipeline file redirect");

queue('pwd &> pwd_output.txt', "", 0, "pwd merged redirect marker");
chain = chain.then(() => job("cat pwd_output.txt").cwd(root).quiet()).then(result => {
  assert(result.text().endsWith("/" + root + "\n"), "pwd merged redirect file");
});
queueFile('echo "hello" &> echo_output.txt', "echo_output.txt", "hello\n",
  "echo merged redirect");
queue('pwd &>> append_output.txt; pwd &>> append_output.txt', "", 0,
  "merged append redirect command");
chain = chain.then(() => job("cat append_output.txt").cwd(root).quiet()).then(result => {
  const lines = result.text().trim().split("\n");
  assert(lines.length === 2 && lines[0] === lines[1], "merged append redirect file");
});

queueFile('echo hello > keepalive.txt', "keepalive.txt", "hello\n",
  "redirect writer completion lifetime");

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-file-io: 51 exact sites"));
