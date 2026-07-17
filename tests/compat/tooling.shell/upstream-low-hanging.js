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

function rejects(job, label) {
  return job.quiet().then(
    () => { throw new Error(label + " must reject"); },
    error => {
      assert(error instanceof Error, label + " error type");
    },
  );
}

check(Clun.$`basename`, 1, "", "usage: basename string\n", "basename usage")
  .then(() => check(Clun.$`basename js/bun/shell/commands/basename.test.ts`, 0,
    "basename.test.ts\n", "", "basename relative"))
  .then(() => check(Clun.$`basename /home/tux/example.txt`, 0,
    "example.txt\n", "", "basename absolute"))
  .then(() => check(Clun.$`basename /usr/share/aclocal/pkg.m4 /var/log/bar/file.txt`, 0,
    "pkg.m4\nfile.txt\n", "", "basename multiple"))
  .then(() => check(Clun.$`basename C:/Documents/Newsletters/Summer2018.pdf`, 0,
    "Summer2018.pdf\n", "", "basename windows"))
  .then(() => check(Clun.$`basename /catalog/`, 0, "catalog\n", "", "basename trailing slash"))
  .then(() => check(Clun.$`basename /catalog`, 0, "catalog\n", "", "basename root child"))
  .then(() => check(Clun.$`basename /`, 0, "/\n", "", "basename root"))
  .then(() => check(Clun.$`echo $(basename js/bun/shell/commands/basename.test.ts)`, 0,
    "basename.test.ts\n", "", "basename substitution relative"))
  .then(() => check(Clun.$`echo $(basename /home/tux/example.txt)`, 0,
    "example.txt\n", "", "basename substitution absolute"))
  .then(() => check(Clun.$`dirname`, 1, "", "usage: dirname string\n", "dirname usage"))
  .then(() => check(Clun.$`dirname js/bun/shell/commands/dirname.test.ts`, 0,
    "js/bun/shell/commands\n", "", "dirname relative"))
  .then(() => check(Clun.$`dirname /home/tux/example.txt`, 0,
    "/home/tux\n", "", "dirname absolute"))
  .then(() => check(Clun.$`dirname /usr/share/aclocal/pkg.m4 /var/log/bar/file.txt`, 0,
    "/usr/share/aclocal\n/var/log/bar\n", "", "dirname multiple"))
  .then(() => check(Clun.$`dirname C:/Documents/Newsletters/Summer2018.pdf`, 0,
    "C:/Documents/Newsletters\n", "", "dirname windows"))
  .then(() => check(Clun.$`dirname /catalog/`, 0, "/\n", "", "dirname trailing slash"))
  .then(() => check(Clun.$`dirname /catalog`, 0, "/\n", "", "dirname root child"))
  .then(() => check(Clun.$`dirname /`, 0, "/\n", "", "dirname root"))
  .then(() => check(Clun.$`echo $(dirname js/bun/shell/commands/dirname.test.ts)`, 0,
    "js/bun/shell/commands\n", "", "dirname substitution relative"))
  .then(() => check(Clun.$`echo $(dirname /home/tux/example.txt)`, 0,
    "/home/tux\n", "", "dirname substitution absolute"))
  .then(() => check(Clun.$`exit`, 0, "", "", "exit default"))
  .then(() => check(Clun.$`exit 0`, 0, "", "", "exit zero"))
  .then(() => check(Clun.$`exit 2`, 2, "", "", "exit two"))
  .then(() => check(Clun.$`exit 11`, 11, "", "", "exit eleven"))
  .then(() => check(Clun.$`exit 3 5`, 1, "", "exit: too many arguments\n", "exit arity"))
  .then(() => check(Clun.$`exit 62757836`, 204, "", "", "exit wraps"))
  .then(() => check(Clun.$`exit abc`, 1, "", "exit: numeric argument required\n", "exit numeric"))
  .then(() => check(Clun.$`true`, 0, "", "", "true"))
  .then(() => check(Clun.$`true 3 5`, 0, "", "", "true arguments"))
  .then(() => check(Clun.$`true --help`, 0, "", "", "true help"))
  .then(() => check(Clun.$`true --version`, 0, "", "", "true version"))
  .then(() => check(Clun.$`false`, 1, "", "", "false"))
  .then(() => check(Clun.$`false 3 5`, 1, "", "", "false arguments"))
  .then(() => check(Clun.$`false --help`, 1, "", "", "false help"))
  .then(() => check(Clun.$`false --version`, 1, "", "", "false version"))
  .then(() => {
    const buffer = Buffer.alloc(10);
    return check(Clun.$`yes > ${buffer}`, 0, "", "", "yes default")
      .then(() => assert(buffer.toString() === "y\ny\ny\ny\ny\n", "yes default buffer"));
  })
  .then(() => {
    const buffer = Buffer.alloc(18);
    return check(Clun.$`yes xy > ${buffer}`, 0, "", "", "yes one argument")
      .then(() => assert(buffer.toString() === "xy\nxy\nxy\nxy\nxy\nxy\n", "yes one-argument buffer"));
  })
  .then(() => {
    const buffer = Buffer.alloc(17);
    return check(Clun.$`yes ab cd ef > ${buffer}`, 0, "", "", "yes arguments")
      .then(() => assert(buffer.toString() === "ab cd ef\nab cd ef", "yes argument buffer"));
  })
  .then(() => {
    const longCommand = "a".repeat(100000);
    return rejects(Clun.$`${longCommand}`, "long command lookup")
      .then(() => rejects(Clun.$`PATH=${longCommand} slkdfjlsdkfj`, "long PATH lookup"));
  })
  .then(() => {
    assert(Clun.$.braces("echo 123").join("|") === "echo 123", "brace no-op");
    assert(Clun.$.braces("echo {123,456}").join("|") === "echo 123|echo 456", "brace pair");
    assert(Clun.$.braces("echo {123,456,789}").join("|") ===
      "echo 123|echo 456|echo 789", "brace triple");
    assert(Clun.$.braces("echo {123,{456,789}}").join("|") ===
      "echo 123|echo 456|echo 789", "brace nested");
    assert(Clun.$.braces("echo {123,{456,789},abc}").join("|") ===
      "echo 123|echo 456|echo 789|echo abc", "brace nested variants");
    assert(Clun.$.braces("{{d,e}{g,h}}").join("|") === "dg|dh|eg|eh", "brace product");
    assert(Clun.$.braces("pre{{a,b}{c,d}}post").join("|") ===
      "preacpost|preadpost|prebcpost|prebdpost", "brace surrounding text");
    assert(Clun.$.braces("{a,{b,c}{d,e},f}").join("|") ===
      "a|bd|be|cd|ce|f", "brace mixed product");
    assert(Clun.$.braces("{{a,b}{c,d}{e,f}}").join("|") ===
      "ace|acf|ade|adf|bce|bcf|bde|bdf", "brace triple product");
    assert(Clun.$.braces(
      "{1,{2,{3,{4,{5,{6,{7,{8,{9,{10,{11,{12,{13,{14,{15,{16,{17}}}}}}}}}}}}}}}}}",
    ).join("|") === "1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17", "brace depth");
    assert(Clun.$.braces("").join("|") === "", "brace empty");
    assert(typeof Clun.$.braces("", { parse: true }) === "string", "brace parse debug");
    assert(typeof Clun.$.braces("", { tokenize: true }) === "string", "brace token debug");
    assert(Clun.$.braces("lol {😂,🫵,🤣}").join("|") === "lol 😂|lol 🫵|lol 🤣", "brace Unicode");
    let errorMessage = "";
    try {
      Clun.$.braces("{".repeat(50000) + "}".repeat(50000));
    } catch (error) {
      errorMessage = error.message;
    }
    assert(errorMessage === "Too many braces in brace expansion", "brace input bound");
    assert(Clun.$.braces("echo {a,b}").join("|") === "echo a|echo b", "brace recovery");
    console.log("upstream-low-hanging: 101 exact sites");
  });
