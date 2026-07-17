function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function decode(value) {
  return new TextDecoder().decode(value);
}

const executable = process.execPath;
const root = "clun-shell-upstream-exec.tmp";
const latin1 = root + "/Í";

function exec(script, options = {}) {
  let command = script === undefined
    ? Clun.$`${executable} exec`
    : Clun.$`${executable} exec ${script}`;
  if (options.cwd !== undefined) command = command.cwd(options.cwd);
  if (options.env !== undefined) command = command.env(options.env);
  return command.quiet().nothrow();
}

function check(result, code, stdout, stderr, label) {
  assert(result.exitCode === code, label + " exit code");
  assert(result.text() === stdout, label + " stdout");
  assert(decode(result.stderr) === stderr, label + " stderr");
}

let chain = Clun.$`rm -rf ${root}; mkdir -p ${latin1}`.quiet();

chain = chain.then(() => exec("echo hi!")).then(result => {
  check(result, 0, "hi!\n", "", "basic");
  return exec("clun-exec-definitely-missing");
}).then(result => {
  check(result, 1, "", "clun: command not found: clun-exec-definitely-missing\n",
    "missing command");
  return exec(undefined);
}).then(result => {
  check(result, 0,
    "Usage: clun exec <script>\n\n" +
    "Execute a shell script directly from Clun.\n\n" +
    "Note: If executing this from a shell, make sure to escape the string!\n\n" +
    "Examples:\n" +
    "  clun exec \"echo hi\"\n" +
    "  clun exec \"echo \\\"hey friends\\\"!\"\n",
    "", "help");
  return exec("echo 'hi \"there bud\"'");
}).then(result => {
  check(result, 0, "hi \"there bud\"\n", "", "quoted script");
  const payload = "a".repeat(128 * 1024);
  return Clun.$`cat < ${Buffer.from(payload)} > ${root}/filename`.quiet()
    .then(() => exec("cat filename", { cwd: root }))
    .then(result => check(result, 0, payload, "", "large output"))
    .then(() => {
      const bytes = new Uint8Array([0, 255, 128, 10, 65]);
      return Clun.$`cat < ${bytes} > ${root}/binary`.quiet()
        .then(() => exec("cat binary", { cwd: root }))
        .then(result => {
          assert(result.exitCode === 0, "binary output status");
          assert(result.stdout.length === bytes.length, "binary output length");
          for (let index = 0; index < bytes.length; index++) {
            assert(result.stdout[index] === bytes[index], "binary output byte " + index);
          }
        });
    });
}).then(() => {
  const programs = [
    ["touch", 1, "", "touch: illegal option -- help\n"],
    ["mkdir", 1, "", "mkdir: illegal option -- help\n"],
    ["echo", 0, "--help\n", ""],
    ["pwd", 1, "", "pwd: too many arguments\n"],
    ["rm", 1, "", "rm: illegal option -- -\n"],
    ["mv", 1, "", "mv: illegal option -- -\n"],
    ["ls", 1, "", "ls: illegal option -- -\n"],
    ["exit", 1, "", "exit: numeric argument required\n"],
    ["true", 0, "", ""],
    ["false", 1, "", ""],
    ["seq", 1, "", "seq: invalid argument\n"],
  ];
  let matrix = Promise.resolve();
  for (const [program, code, stdout, stderr] of programs) {
    matrix = matrix.then(() => exec(program + " --help"))
      .then(result => check(result, code, stdout, stderr, program + " help"));
  }
  return matrix;
}).then(() => exec("cd")).then(result => {
  check(result, 0, "", "", "cd default");
  return exec("clun --version", {
    env: { PATH: "", TMPDIR: process.env.TMPDIR },
  });
}).then(result => {
  assert(result.exitCode === 0, "self executable status");
  assert(result.text().startsWith("clun 0.1.0-dev."), "self executable stdout");
  assert(decode(result.stderr) === "", "self executable stderr");
  return Clun.$`echo -n text > ${latin1}/hi`.quiet();
}).then(() => exec("ls", { cwd: latin1 })).then(result => {
  check(result, 0, "hi\n", "", "latin1 cwd");
  return Clun.$`rm -rf ${root}`.quiet();
}).then(() => console.log("upstream-exec: 18 exact sites"));
