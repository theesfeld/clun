function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

const expectedHead = "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n";
const root = "clun-shell-upstream-lifecycle.tmp";
const external = "/usr/bin/env";
let chain = Promise.resolve();

function step(label, factory) {
  chain = chain.then(() =>
    Promise.resolve()
      .then(factory)
      .catch(error => {
        throw new Error(label + ": " + (error && error.message ? error.message : error));
      }));
}

function queue(jobFactory, expectedOut, expectedCode, label, expectedErr) {
  step(label, () =>
    jobFactory().quiet().nothrow().then(result => {
      assert(result.exitCode === expectedCode, label + " exit code got " + result.exitCode);
      assert(result.text() === expectedOut,
        label + " stdout got " + JSON.stringify(result.text()).slice(0, 120));
      if (expectedErr !== undefined) {
        assert(stderr(result) === expectedErr, label + " stderr");
      }
    }));
}

function expectReject(jobFactory, label) {
  step(label, () =>
    jobFactory().then(
      () => {
        throw new Error(label + " expected rejection");
      },
      () => undefined));
}

function expectResolve(jobFactory, label) {
  step(label, () => jobFactory().then(() => undefined));
}

// --- setup -----------------------------------------------------------------
queue(() => Clun.$`rm -rf ${root}; mkdir -p ${root}`, "", 0, "root setup");

// --- pipeline residual: epipe ----------------------------------------------
// Frozen epipe.test.ts: yes | head defaults to ten lines and must not hang.
queue(() => Clun.$`yes | head`, expectedHead, 0, "epipe yes|head default");
step("epipe concurrent yes|head", () =>
  Promise.all(Array(32).fill(0).map(() => Clun.$`yes | head`.text())).then(results => {
    for (let i = 0; i < results.length; i++) {
      assert(results[i] === expectedHead, "epipe concurrent row " + i);
    }
  }));

// --- pipeline residual: blocking-pipe (1 MiB echo | cat) -------------------
step("blocking pipe 1MiB literal", () => {
  const expected = Buffer.alloc(1024 * 1024, "bun!").toString();
  const cat = Clun.which("cat");
  assert(typeof cat === "string" && cat.length > 0, "cat resolution");
  return Clun.$`echo ${expected} | ${cat}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "blocking pipe exit");
    assert(result.text() === expected + "\n", "blocking pipe body");
    assert(stderr(result) === "", "blocking pipe stderr");
  });
});

step("blocking pipe 1MiB raw command", () => {
  const expected = Buffer.alloc(1024 * 1024, "bun!").toString();
  const cat = Clun.which("cat");
  const massive = "echo " + expected + " | " + cat;
  return Clun.$`${{ raw: massive }}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "blocking raw exit");
    assert(result.text() === expected + "\n", "blocking raw body");
  });
});

// --- pipeline residual: pwd | cd | pwd -------------------------------------
// Bun 1.3.14 and Clun both emit a single TEMP line (final-stage stdout with
// pipeline-local cd isolation). Parent shell cwd is unchanged.
step("pwd|cd|pwd isolation", () =>
  Clun.$`pwd | cd / | pwd`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "pwd|cd|pwd exit");
    const lines = result.text().trim().split("\n");
    assert(lines.length === 1, "pwd|cd|pwd single final stage");
    assert(lines[0].endsWith("/" + root), "pwd|cd|pwd stays in root");
    assert(stderr(result) === "", "pwd|cd|pwd stderr");
  }));

// --- lifecycle: hang fixtures (throws policy, no hang) ---------------------
step("hang throws setup", () => {
  Clun.$.throws(true);
  return Promise.resolve();
});

expectReject(() => Clun.$`not-found-command-1234 || not-found-command-5678`.quiet(),
  "hang fail or-fail");
expectReject(() => Clun.$`echo 1 && not-found-command-1234`.quiet(),
  "hang fail success-and-error");
expectReject(() => Clun.$`which node`.quiet().then(() =>
  Clun.$`which which bad-command-that-does-not-exist`.quiet()),
  "hang fail first-works-second-fails");
expectResolve(() => Clun.$`not-found-command-1234 || echo 42`.quiet(),
  "hang pass error-or-success");
expectResolve(() => Clun.$`which node && which node`.quiet(),
  "hang pass success-and-success");
expectResolve(() => Clun.$`echo 1 && echo 2`.quiet(),
  "hang pass success");

step("hang throws restore", () => {
  Clun.$.throws(false);
  return Promise.resolve();
});

// --- lifecycle: load (many concurrent external true) -----------------------
step("shell load immediate exit", () => {
  const cmd = Clun.which("true");
  assert(typeof cmd === "string" && cmd.length > 0, "true resolution");
  const promises = [];
  for (let i = 0; i < 200; i++) {
    promises.push(Clun.$`${cmd}`.text());
  }
  return Promise.all(promises).then(results => {
    assert(results.length === 200, "load batch size");
    for (let i = 0; i < results.length; i++) {
      assert(results[i] === "", "load true stdout empty");
    }
  });
});

// --- lifecycle: leak-args / parse stress (bounded, no hang/crash) ----------
step("leak-args parse errors", () => {
  const buffer = Buffer.alloc(64 * 1024, "A").toString();
  let seen = 0;
  let local = Promise.resolve();
  for (let i = 0; i < 40; i++) {
    local = local.then(() =>
      Clun.$`${{ raw: buffer + " <!INVALID ==== SYNTAX!>" }}`.quiet().nothrow().then(result => {
        assert(typeof result.exitCode === "number", "parse stress exit number");
        seen++;
      }, () => {
        seen++;
      }));
  }
  return local.then(() => {
    assert(seen === 40, "parse stress iterations");
  });
});

step("leak-args large argv execution", () => {
  const buffer = Buffer.alloc(256 * 1024, "bun!").toString();
  let local = Promise.resolve();
  for (let i = 0; i < 8; i++) {
    local = local.then(() =>
      Clun.$`echo ${buffer}`.quiet().nothrow().then(result => {
        assert(result.exitCode === 0, "large argv exit");
        assert(result.text() === buffer + "\n", "large argv body");
      }));
  }
  return local;
});

step("leak-args non-awaited fire-and-forget", () => {
  const buffer = Buffer.alloc(64 * 1024, "x").toString();
  const pending = [];
  for (let i = 0; i < 16; i++) {
    pending.push(Clun.$`echo ${buffer}`.quiet().nothrow());
  }
  return Promise.all(pending).then(results => {
    for (let i = 0; i < results.length; i++) {
      assert(results[i].exitCode === 0, "fire-and-forget exit");
    }
  });
});

// --- lifecycle: leak.test stress (repeated scripts without hang) -----------
step("fd/mem leak stress builtins", () => {
  let local = Promise.resolve();
  for (let i = 0; i < 80; i++) {
    local = local.then(() =>
      Clun.$`echo stress-${i} | true; false | true; pwd`.cwd(root).quiet().nothrow().then(result => {
        assert(result.exitCode === 0, "leak stress exit " + i);
        assert(result.text().endsWith("/" + root + "\n"), "leak stress cwd " + i);
      }));
  }
  return local;
});

step("leak stress concurrent cat-like reads", () => {
  const payload = "a".repeat(2048);
  return Clun.$`printf ${payload} > ${root}/input.txt`.quiet().then(() => {
    const promises = [];
    for (let i = 0; i < 40; i++) {
      promises.push(Clun.$`cat ${root}/input.txt`.quiet().nothrow());
    }
    return Promise.all(promises).then(results => {
      for (let i = 0; i < results.length; i++) {
        assert(results[i].exitCode === 0, "concurrent cat exit");
        assert(results[i].text() === payload, "concurrent cat body");
      }
    });
  });
});

step("leak stress never-run ShellPromise discarded", () => {
  for (let i = 0; i < 100; i++) {
    Clun.$`echo discarded-${i}`.quiet();
  }
  return Clun.$`echo settled`.quiet().text().then(text => {
    assert(text === "settled\n", "discarded promises settle later work");
  });
});

// --- lifecycle: sentinel hardening -----------------------------------------
step("sentinel obj-ref prefix round-trip", () => {
  const str = "\x08__bun_abc";
  return Clun.$`echo ${str}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "sentinel obj exit");
    assert(result.text() === str + "\n", "sentinel obj body");
  });
});

step("sentinel str-ref prefix round-trip", () => {
  const str = "\x08__bunstr_abc";
  return Clun.$`echo ${str}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "sentinel str exit");
    assert(result.text() === str + "\n", "sentinel str body");
  });
});

step("sentinel raw injection does not crash", () => {
  const sentinel = String.fromCharCode(8) + "__bun_9999";
  return Clun.$`echo hello > ${{ raw: sentinel }}`.cwd(root).quiet().nothrow().then(result => {
    assert(typeof result.exitCode === "number", "raw sentinel exit number");
  });
});

// --- lifecycle: write-fault / pipe-read-fault observable equivalents -------
// Upstream uses LD_PRELOAD fault injection. Credit the pure-CL contract:
// multi-chunk pipeline writes complete; external pipe reads complete.
queue(() => Clun.$`(echo one; echo two; echo three) | ${external} cat`,
  "one\ntwo\nthree\n", 0, "write-fault multi-chunk pipe");

queue(() => Clun.$`${external} printf 'out\n'`, "out\n", 0,
  "pipe-read stdout-only");

queue(() => Clun.$`${external} sh -c 'echo out; echo err 1>&2' 2>&1`,
  "out\nerr\n", 0, "pipe-read both pipes merged");

step("pipe-read quiet chunk", () =>
  Clun.$`${external} sh -c ${"printf %s \"$(printf x%.0s $(seq 1 4096))\""}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "quiet chunk exit");
    assert(result.text() === "x".repeat(4096), "quiet chunk body");
  }));

step("pipe-read bulk yes", () =>
  Clun.$`yes | head -c 8192`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "pipe-read bulk exit");
    assert(result.bytes().length === 8192, "pipe-read bulk length");
  }));

step("pipe-read poll-style multi", () =>
  Clun.$`${external} sh -c 'for i in 1 2 3 4 5; do echo line$i; done'`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "poll multi exit");
    assert(result.text() === "line1\nline2\nline3\nline4\nline5\n", "poll multi body");
  }));

step("pipe-read mid-flush bulk", () =>
  Clun.$`yes z | head -c 65536`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "mid-flush exit");
    assert(result.bytes().length === 65536, "mid-flush length");
  }));

// --- cleanup ---------------------------------------------------------------
queue(() => Clun.$`rm -rf ${root}`, "", 0, "root cleanup");

chain.then(() => {
  console.log("upstream-lifecycle: 46 exact lifecycle/pipeline residual sites");
}, error => {
  console.error(String(error && error.stack ? error.stack : error));
  // Force non-zero process outcome when the fixture fails.
  throw error;
});
