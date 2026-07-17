function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function bytesText(value) {
  return new TextDecoder().decode(value);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

function rejected(promise, check, label) {
  return promise.then(
    () => { throw new Error(label + " must reject"); },
    error => {
      check(error);
      return error;
    },
  );
}

const root = "clun-shell-upstream-public-api.tmp";
const missing = "clun-shell-public-api-definitely-missing";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

chain = chain.then(() => {
  const child = new Clun.$.Shell();
  child.env({ CLUN_SHELL_INSTANCE: "child" });
  return child`echo $CLUN_SHELL_INSTANCE`.text().then(text => {
    assert(text === "child\n", "child environment");
    return Clun.$`echo $CLUN_SHELL_INSTANCE`.text();
  }).then(text => {
    assert(text === "\n", "child does not mutate parent");
    Clun.$.env({ CLUN_SHELL_INSTANCE: "parent" });
    return child`echo $CLUN_SHELL_INSTANCE`.text();
  }).then(text => {
    assert(text === "child\n", "parent does not mutate child");
    return Clun.$`echo $CLUN_SHELL_INSTANCE`.text();
  }).then(text => assert(text === "parent\n", "parent environment"));
});

chain = chain.then(() => Clun.$`echo hello`.text()).then(text => {
  assert(text === "hello\n", "text helper");
  return Clun.$`echo '{"hello": 123}'`.json();
}).then(value => {
  assert(value.hello === 123, "json helper");
  return Clun.$`echo hello`.arrayBuffer();
}).then(buffer => {
  assert(bytesText(new Uint8Array(buffer)) === "hello\n", "arrayBuffer helper");
  return Clun.$`echo hello`.bytes();
}).then(bytes => {
  assert(bytesText(bytes) === "hello\n", "bytes helper");
  return Clun.$`echo hello`.blob();
}).then(blob => {
  assert(blob instanceof Blob, "blob helper brand");
  assert(blob.size === 6 && blob.type === "", "blob helper metadata");
  return blob.text();
}).then(text => {
  assert(text === "hello\n", "blob helper bytes");
  const iterator = Clun.$`echo hello`.lines();
  assert(iterator[Symbol.asyncIterator]() === iterator, "lines iterator identity");
  return iterator.next().then(first => {
    assert(first.value === "hello" && first.done === false, "lines first");
    return iterator.next();
  }).then(second => {
    assert(second.value === "" && second.done === false, "lines trailing empty");
    return iterator.next();
  }).then(last => assert(last.done === true, "lines completion"));
});

const payload = "hello world!".repeat(9000);
chain = chain.then(() => {
  const blob = new Blob([payload], { type: "TEXT/PLAIN" });
  assert(blob instanceof Blob, "Blob constructor brand");
  assert(blob.size === payload.length && blob.type === "text/plain", "Blob metadata");
  return blob.text().then(text => assert(text === payload, "Blob text"));
}).then(() => Clun.$`cat < ${new Blob([payload])}`.text()).then(text => {
  assert(text === payload, "Blob stdin");
  return Clun.$`cat < ${Buffer.from(payload)}`.text();
}).then(text => {
  assert(text === payload, "Buffer stdin");
  return Clun.$`cat < ${new TextEncoder().encode(payload)}`.text();
}).then(text => {
  assert(text === payload, "Uint8Array stdin");
  return Clun.$`cat < ${new Response(payload)}`.text();
}).then(text => assert(text === payload, "Response stdin"));

chain = chain.then(() => {
  const input = Buffer.from(payload);
  const output = Buffer.alloc(input.length);
  return Clun.$`cat < ${input} > ${output}`.quiet().then(result => {
    assert(result.exitCode === 0 && result.text() === "", "Buffer stdout status");
    assert(output.toString() === payload, "Buffer stdout bytes");
  });
}).then(() => {
  const input = new TextEncoder().encode(payload);
  const output = new Uint8Array(input.length);
  return Clun.$`cat < ${input} > ${output}`.quiet().then(result => {
    assert(result.exitCode === 0, "Uint8Array stdout status");
    assert(bytesText(output) === payload, "Uint8Array stdout bytes");
  });
}).then(() => rejected(
  Clun.$`echo no > ${new Blob([])}`.text(),
  error => assert(error instanceof TypeError, "Blob stdout error type"),
  "Blob stdout",
)).then(() => rejected(
  Clun.$`echo no > ${new Response()}`.text(),
  error => assert(error instanceof TypeError, "Response stdout error type"),
  "Response stdout",
));

chain = chain.then(() => rejected(
  job(`echo hi; ls ${missing}`).quiet(),
  error => {
    assert(error instanceof Error && error instanceof Clun.$.ShellError,
      "default ShellError brand");
    assert(error.exitCode === 1 && error.message === "Failed with exit code 1",
      "default ShellError status");
    assert(error.text() === "hi\n", "ShellError text");
    assert(stderr(error) === `ls: ${missing}: No such file or directory\n`,
      "ShellError stderr");
    assert(error.json === undefined || typeof error.json === "function", "ShellError shape");
    const blob = error.blob();
    assert(blob instanceof Blob && blob.size === 3, "ShellError blob");
  },
  "default throw",
));

chain = chain.then(() => {
  Clun.$.throws(true);
  return rejected(job(`ls ${missing}`).quiet(), error => {
    assert(error.exitCode === 1, "global throws enabled");
  }, "global throws");
}).then(() => {
  Clun.$.nothrow();
  return job(`ls ${missing}`).quiet();
}).then(result => {
  assert(result.exitCode === 1, "global nothrow");
  Clun.$.throws(true);
  return job(`ls ${missing}`).quiet().nothrow();
}).then(result => {
  assert(result.exitCode === 1, "local nothrow");
  Clun.$.nothrow();
  return rejected(job(`ls ${missing}`).quiet().throws(true), error => {
    assert(error.exitCode === 1, "local throws enabled");
  }, "local throws");
});

chain = chain.then(() => {
  const pending = job("echo 123 > lazy.txt").cwd(root).quiet();
  return job("echo 456 > lazy.txt; cat lazy.txt").cwd(root).text().then(text => {
    assert(text === "456\n", "lazy job has not started");
    return pending;
  }).then(() => job("cat lazy.txt").cwd(root).text()).then(text => {
    assert(text === "123\n", "lazy job starts when awaited");
  });
});

chain = chain.then(() => {
  const fixturePath = "upstream-public-api.js";
  const file = Clun.file(fixturePath);
  return Clun.$`echo ${file}`.text().then(text => {
    assert(text === fixturePath + "\n", "Clun.file interpolation");
    return Clun.$`echo ${fixturePath}`.text();
  }).then(text => assert(text === fixturePath + "\n", "path interpolation"));
});

chain = chain.then(() => {
  const words = Array(10000).fill("a");
  return Clun.$`echo -n ${words} > wide.txt`.cwd(root).quiet().then(result => {
    assert(result.exitCode === 0, "wide interpolation status");
    return job("cat wide.txt").cwd(root).text();
  }).then(text => assert(text === words.join(" "), "wide interpolation output"));
});

chain = chain.then(() => {
  if (process.platform !== "linux") return undefined;
  return job("echo $(echo $(echo $(echo a > /dev/full) > /dev/full) > /dev/full) > /dev/full || echo outer_write_failed")
    .quiet().nothrow().then(result => {
      assert(result.exitCode === 0 && result.text() === "outer_write_failed\n",
        "nested synchronous write errors");
      return job("echo a > /dev/full || echo f1; echo b > /dev/full || echo f2; echo c > /dev/full || echo f3; echo d > /dev/full || echo f4")
        .quiet().nothrow();
    }).then(result => {
      assert(result.exitCode === 0 && result.text() === "f1\nf2\nf3\nf4\n",
        "sequential synchronous write errors");
    });
});

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-public-api: 50 exact sites"));
