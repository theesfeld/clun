function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const hostile = "safe; printf INJECTED $(printf BAD) *";
const outputPath = "clun-shell-core-output.tmp";
const bothPath = "clun-shell-core-both.tmp";
const orderedPath = "clun-shell-core-ordered.tmp";
const replacedPath = "clun-shell-core-replaced.tmp";
const finalPath = "clun-shell-core-final.tmp";

Clun.$`printf "%s\n" ${hostile}`.text()
  .then(text => {
    assert(text === hostile + "\n", "interpolation must be one inert argument");
    console.log("safe-interpolation");
    return Clun.$`printf "[%s]\n" ${["a b", "c"]}`.text();
  })
  .then(text => {
    assert(text === "[a b]\n[c]\n", "array interpolation must preserve argument boundaries");
    console.log("array-interpolation");
    return Clun.$`printf hello | tr a-z A-Z`.text();
  })
  .then(text => {
    assert(text === "HELLO", "pipeline output");
    console.log("pipeline");
    return Clun.$`yes x | head -c 1048576`.bytes();
  })
  .then(bytes => {
    assert(bytes.length === 1048576, "pipeline must drain output beyond pipe capacity");
    console.log("pipeline-backpressure");
    return Clun.$`false || echo recovered`.text();
  })
  .then(text => {
    assert(text === "recovered\n", "logical OR");
    console.log("logical-operators");
    return Clun.$`echo $(printf sub)`.text();
  })
  .then(text => {
    assert(text === "sub\n", "command substitution");
    console.log("command-substitution");
    return Clun.$`echo $CLUN_SHELL_VALUE`.env({ CLUN_SHELL_VALUE: "from-env" }).text();
  })
  .then(text => {
    assert(text === "from-env\n", "per-command environment");
    return Clun.$`pwd`.cwd(".").text();
  })
  .then(text => {
    assert(text.length > 1 && text.endsWith("tooling.shell\n"), "relative cwd");
    console.log("env-and-cwd");
    return Clun.$`printf redirected > ${outputPath}`;
  })
  .then(() => Clun.$`cat ${outputPath}`.text())
  .then(text => {
    assert(text === "redirected", "output redirection");
    console.log("redirection");
    return Clun.$`ls ${outputPath} clun-shell-core-missing > ${bothPath} 2>&1`
      .quiet().nothrow();
  })
  .then(result => {
    assert(result.exitCode === 1 && result.text() === "" && result.stderr.length === 0,
      "stdout then stderr duplication must fully redirect");
    return Clun.$`echo appended &>> ${bothPath}; cat ${bothPath}`.text();
  })
  .then(text => {
    assert(text.includes(outputPath + "\n"), "combined redirect stdout");
    assert(text.includes("ls: clun-shell-core-missing: No such file or directory\n"),
      "combined redirect stderr");
    assert(text.endsWith("appended\n"), "combined append redirect");
    return Clun.$`ls ${outputPath} clun-shell-core-missing 2>&1 > ${orderedPath}`
      .quiet().nothrow();
  })
  .then(result => {
    assert(result.exitCode === 1, "ordered redirect exit code");
    assert(result.text() === "ls: clun-shell-core-missing: No such file or directory\n",
      "stderr must retain the snapshotted original stdout destination");
    assert(result.stderr.length === 0, "duplicated stderr must leave stderr capture empty");
    return Clun.$`cat ${orderedPath}`.text();
  })
  .then(text => {
    assert(text === outputPath + "\n", "later stdout redirect must not move duplicated stderr");
    return Clun.$`printf final > ${replacedPath} > ${finalPath}; cat ${replacedPath}`.text();
  })
  .then(text => {
    assert(text === "", "superseded redirect still creates an empty file");
    return Clun.$`cat ${finalPath}`.text();
  })
  .then(text => {
    assert(text === "final", "last redirect receives stdout");
    console.log("descriptor-redirection");
    return Clun.$`rm ${[outputPath, bothPath, orderedPath, replacedPath, finalPath]}`.nothrow();
  })
  .then(result => {
    assert(result.exitCode === 0, "cleanup command");
    return Clun.$`false`.nothrow();
  })
  .then(result => {
    assert(result.exitCode === 1, "nothrow exit code");
    assert(result.text() === "", "ShellOutput text helper");
    console.log("structured-output");
    return Clun.$`false`.text();
  }, error => {
    throw error;
  })
  .then(() => {
    throw new Error("nonzero shell command must reject");
  }, error => {
    assert(error.name === "ShellError", "ShellError name");
    assert(error.message === "Failed with exit code 1", "ShellError message");
    assert(error.exitCode === 1, "ShellError exit code");
    assert(error.text() === "", "ShellError text helper");
    assert(error instanceof Clun.$.ShellError, "ShellError constructor brand");
    assert(error instanceof Error, "ShellError must inherit Error");
    console.log("structured-error");
    assert(Clun.$.escape("a b") === '"a b"', "escape helper");
    assert(Clun.$.braces("x{a,b}y").join(",") === "xay,xby", "brace helper");
    assert(Clun.$.braces("echo 123").join("|") === "echo 123", "brace no-op");
    assert(Clun.$.braces("echo {123,{456,789},abc}").join("|") ===
      "echo 123|echo 456|echo 789|echo abc", "nested brace variants");
    assert(Clun.$.braces("pre{{a,b}{c,d}}post").join("|") ===
      "preacpost|preadpost|prebcpost|prebdpost", "nested brace product");
    assert(Clun.$.braces("{a,{b,c}{d,e},f}").join("|") ===
      "a|bd|be|cd|ce|f", "mixed brace variants and products");
    assert(Clun.$.braces("{{a,b}{c,d}{e,f}}").join("|") ===
      "ace|acf|ade|adf|bce|bcf|bde|bdf", "triple brace product");
    assert(Clun.$.braces("lol {😂,🫵,🤣}").join("|") === "lol 😂|lol 🫵|lol 🤣",
      "Unicode brace variants");
    assert(Clun.$.braces(
      "{1,{2,{3,{4,{5,{6,{7,{8,{9,{10,{11,{12,{13,{14,{15,{16,{17}}}}}}}}}}}}}}}}}"
    ).join("|") === "1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17",
    "deep nested brace variants");
    assert(Clun.$.braces("").join("|") === "", "empty brace input");
    assert(Clun.$.braces("", { tokenize: true }) === '["eof"]',
      "brace token debug output");
    assert(Clun.$.braces("", { parse: true }) ===
      '{"bubble_up":null,"bubble_up_next":null,"atoms":{"many":[]}}',
    "brace AST debug output");
    let braceBoundError = "";
    try {
      Clun.$.braces("{".repeat(257) + "}".repeat(257));
    } catch (error) {
      braceBoundError = error.message;
    }
    assert(braceBoundError === "Too many braces in brace expansion", "brace group bound");
    let braceResultError = "";
    try {
      Clun.$.braces("{a,b}".repeat(17));
    } catch (error) {
      braceResultError = error.message;
    }
    assert(braceResultError === "Too many brace expansions (131072 > 65536)",
      "brace result bound");
    console.log("brace-expansion");
    console.log("helpers");
    const manual = new Clun.$.ShellError("manual");
    assert(manual instanceof Clun.$.ShellError && manual instanceof Error,
      "manual ShellError prototype chain");
    const chain = Clun.$`true`.quiet().then(result => result.exitCode);
    assert(chain instanceof Promise, "ShellPromise.then must return a Promise");
    return chain;
  })
  .then(exitCode => {
    assert(exitCode === 0, "ShellPromise.then result");
    return Clun.$`false`.quiet().catch(error => error.exitCode);
  })
  .then(exitCode => {
    assert(exitCode === 1, "ShellPromise.catch result");
    let finalized = 0;
    return Clun.$`true`.quiet().finally(() => { finalized++; })
      .then(() => finalized);
  })
  .then(finalized => {
    assert(finalized === 1, "ShellPromise.finally result");
    console.log("promise-chain");
    return Clun.$`printf nope`
      .env({ PATH: "/definitely/missing" }).quiet().nothrow();
  })
  .then(result => {
    assert(result.exitCode === 127, "job PATH must control executable lookup");
    console.log("path-lookup");
    const running = Clun.$`echo run-once`.quiet();
    assert(running.run() === running, "run returns the same ShellPromise");
    return running;
  })
  .then(result => {
    assert(result.text() === "run-once\n", "run starts the shell job");
    const iterator = Clun.$`echo hello`.lines();
    assert(iterator[Symbol.asyncIterator]() === iterator, "lines async iterator identity");
    return iterator.next().then(first => {
      assert(first.value === "hello" && first.done === false, "lines first value");
      return iterator.next();
    }).then(second => {
      assert(second.value === "" && second.done === false, "lines trailing empty value");
      return iterator.next();
    }).then(last => {
      assert(last.done === true, "lines completion");
      console.log("shell-promise-api");
      let bareCallError = "";
      try {
        Clun.$.Shell();
      } catch (error) {
        bareCallError = error.name + ": " + error.message;
      }
      assert(bareCallError === "TypeError: Class constructor Shell cannot be invoked without 'new'",
        "Shell constructor requires new");
      const child = new Clun.$.Shell();
      assert(typeof child === "function", "Shell instance is a callable tag");
      assert(child instanceof Clun.$.Shell, "Shell instance prototype");
      child.env({ CLUN_SHELL_INSTANCE_VALUE: "child" });
      return child`echo $CLUN_SHELL_INSTANCE_VALUE`.text().then(childText => {
        assert(childText === "child\n", "child shell environment");
        return Clun.$`echo $CLUN_SHELL_INSTANCE_VALUE`.text();
      }).then(parentText => {
        assert(parentText === "\n", "child environment must not alter parent");
        Clun.$.env({ CLUN_SHELL_INSTANCE_VALUE: "parent" });
        return child`echo $CLUN_SHELL_INSTANCE_VALUE`.text();
      }).then(childText => {
        assert(childText === "child\n", "parent environment must not alter child");
        return Clun.$`echo $CLUN_SHELL_INSTANCE_VALUE`.text();
      }).then(parentText => {
        assert(parentText === "parent\n", "parent shell environment");
        Clun.$.env();
        console.log("shell-instance");
      });
    });
  });
