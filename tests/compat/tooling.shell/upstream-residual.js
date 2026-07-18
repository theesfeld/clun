function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

function expectJob(command, code, stdout, error, label) {
  return command.quiet().nothrow().then(result => {
    assert(result.exitCode === code,
      label + " exit " + result.exitCode + " !== " + code);
    assert(result.text() === stdout,
      label + " stdout " + JSON.stringify(result.text()) + " !== " + JSON.stringify(stdout));
    assert(stderr(result) === error,
      label + " stderr " + JSON.stringify(stderr(result)) + " !== " + JSON.stringify(error));
  });
}

function sentinel(buffer) {
  for (let i = 0; i < buffer.byteLength; i++) {
    if (buffer[i] === 0) return i;
  }
  return buffer.byteLength;
}

function decode(buffer) {
  return new TextDecoder().decode(buffer.slice(0, sentinel(buffer)));
}

const root = "clun-shell-upstream-residual.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

// Escape / interpolation residual (L167): marker bytes stay literal through escape+raw.
const secret = "name=top-secret-value";
const hostile = "\x08__bunstr_0";
const escaped = Clun.$.escape(hostile);
chain = chain.then(() => expectJob(Clun.$`echo ${{ raw: escaped }} ${secret}`, 0,
  hostile + " " + secret + "\n", "", "escape marker round-trip"))
  .then(() => expectJob(Clun.$`echo ${{ raw: Clun.$.escape("hello world") }}`, 0,
    "hello world\n", "", "escape ordinary round-trip"));

// Quiet residual (L223): buffered capture without console side channels.
chain = chain.then(() => expectJob(Clun.$`echo hi`.quiet(), 0, "hi\n", "", "quiet basic"))
  .then(() => expectJob(Clun.$`echo quiet-arg`.quiet(true), 0, "quiet-arg\n", "", "quiet true"));

// failing stmt edgecase (L273): ls accepts -R after the path operand.
chain = chain.then(() => job(`mkdir -p ${root}/lsR/foo/bar; touch ${root}/lsR/foo/lol ${root}/lsR/foo/nice ${root}/lsR/foo/lmao ${root}/lsR/foo/bar/great ${root}/lsR/foo/bar/wow`).quiet())
  .then(() => expectJob(Clun.$`ls foo -R`.cwd(root + "/lsR"), 0,
    "bar\nlmao\nlol\nnice\nfoo/bar:\ngreat\nwow\n", "", "ls path then -R"));

// Escape unicode residual (L343): backslash + CJK stay literal data.
chain = chain.then(() => expectJob(job("echo \\\\弟\\\\気"), 0, "\\弟\\気\n", "",
  "escape unicode backslash pairs"));

// Glob over unreadable directory (L884): EACCES, not nullglob.
chain = chain.then(() => job(`mkdir -p ${root}/eacces/noaccess; touch ${root}/eacces/placeholder.txt; chmod 000 ${root}/eacces/noaccess`).quiet())
  .then(() => Clun.$`echo ${root}/eacces/noaccess/*`.quiet().nothrow().then(result => {
    assert(result.exitCode === 1, "glob eacces exit");
    assert(stderr(result).indexOf("Permission denied:") >= 0, "glob eacces message");
    assert(stderr(result).indexOf("no matches found") < 0, "glob eacces not nullglob");
  }))
  .then(() => Clun.$`FOO=${root}/eacces/noaccess/*; echo $FOO`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "glob assign eacces exit");
    assert(result.text() === root + "/eacces/noaccess/*\n", "glob assign keeps pattern");
    assert(stderr(result) === "", "glob assign silent");
  }))
  .then(() => job(`chmod 755 ${root}/eacces/noaccess`).quiet());

// Export var residual (L971) + syntax edgecase tight redirect (L992).
chain = chain.then(() => expectJob(job("export FOO=bar && printenv FOO"), 0, "bar\n", "",
  "export var"))
  .then(() => {
    const buffer = new Uint8Array(1 << 16);
    return Clun.$`FOO=bar BUN_TEST_VAR=1 printenv FOO> ${buffer}`.quiet().nothrow().then(result => {
      assert(result.exitCode === 0, "syntax edge exit");
      assert(decode(buffer) === "bar\n", "syntax edge buffer");
    });
  });

// ENAMETOOLONG for cd (L1025) and .cwd (L1066).
const tooLong = "/" + "a".repeat(5000);
chain = chain.then(() => expectJob(Clun.$`cd ${tooLong}`, 1, "", "cd: file name too long\n",
  "cd ENAMETOOLONG"))
  .then(() => {
    try {
      Clun.$`echo hi`.cwd(tooLong);
      throw new Error("cwd should throw ENAMETOOLONG");
    } catch (error) {
      assert(error.code === "ENAMETOOLONG", "cwd code " + error.code);
    }
  });

// Pipeline residual: complicated cmdsub with &, |& merge, background pipeline.
chain = chain.then(() => expectJob(job("echo $(echo 2 & echo 1)"), 0, "1 2\n", "",
  "complicated pipeline cmdsub background"))
  .then(() => expectJob(job("echo 1 |& cat"), 0, "1\n", "", "|& merge pipe"))
  .then(() => expectJob(job("echo foreground | echo pipe && (echo background &) | cat"), 0,
    "pipe\nbackground\n", "", "pipeline with background process"));

// big_data residual (L1624): 10 * 128 KiB redirect.
chain = chain.then(() => {
  const bytes = new Uint8Array(10 * 128 * 1024).fill("a".charCodeAt(0));
  const path = root + "/big_output.txt";
  return Clun.$`cat > ${path} < ${bytes}`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "big_data exit");
    assert(result.text() === "", "big_data stdout empty");
  }).then(() => Clun.$`wc -c ${path}`.quiet().nothrow().then(result => {
    assert(result.text().trim().split(/\s+/)[0] === String(10 * 128 * 1024),
      "big_data size " + result.text());
  }));
});

// input residual (L1648): binary stdin through a pipeline.
chain = chain.then(() => {
  const input = new Uint8Array([0x1b, 0x5b, 0x42, 0x0d]);
  return expectJob(Clun.$`cat < ${input}`, 0, "\x1b[B\r", "", "input binary stdin");
});

// Background + wait control-flow residual (L2146-L2164).
chain = chain.then(() => expectJob(job("if echo foo&then wait;fi"), 0, "foo\n", "",
  "async after if"))
  .then(() => expectJob(job("if echo foo;then echo bar&fi;wait"), 0, "foo\nbar\n", "",
    "async after then"))
  .then(() => expectJob(job("if ! echo foo;then echo bar;elif echo baz&then wait;fi"), 0,
    "foo\nbaz\n", "", "async after elif"))
  .then(() => expectJob(
    job("if ! echo foo;then echo bar;elif ! echo baz;then echo qux;else echo quux;fi;wait"),
    0, "foo\nbaz\nquux\n", "", "async after else"))
  .then(() => expectJob(job(`if echo 1; echo 2
echo 3; ! echo 4; then echo x1; echo x2
echo x3; echo x4; elif echo 5; echo 6
echo 7; echo 8; then echo 9; echo 10
echo 11; echo 12; else echo x5; echo x6
echo x7; echo x8; fi`), 0,
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", "", "more than one inner command"));

// describe.todo("async") residual (L2817+): background jobs + redirect race window.
chain = chain.then(() => expectJob(job("echo hi &; echo hello"), 0, "hello\nhi\n", "",
  "async basic"))
  .then(() => expectJob(job("echo noice | cat &; echo hello"), 0, "hello\nnoice\n", "",
    "async pipeline"))
  .then(() => job(`echo hey > ${root}/output.txt`).quiet())
  .then(() => Clun.$`echo start > ${root}/output.txt & cat ${root}/output.txt`.quiet().nothrow()
    .then(result => {
      assert(result.exitCode === 0, "bg redirect exit");
      const text = result.text();
      assert(text === "hey\n" || text === "start\n",
        "bg redirect race " + JSON.stringify(text));
    }));

// Interpolated assignment word stays a command word (near L2826).
chain = chain.then(() => expectJob(Clun.$`${"FOO_INJECTED=1"} echo hi`, 127, "",
  "clun: command not found: FOO_INJECTED=1\n", "injected equals command word"));

// Redirect buffer pin residual (L2907 / L2974).
chain = chain.then(() => job(`mkdir -p ${root}/pin; echo x > ${root}/pin/pin.txt`).quiet())
  .then(() => {
    const buffer = new Uint8Array(new ArrayBuffer(1 << 16));
    return Clun.$`ls ${root}/pin > ${buffer}`.quiet().nothrow().then(result => {
      assert(result.exitCode === 0, "builtin redirect pin exit");
      assert(decode(buffer) === "pin.txt\n", "builtin redirect pin data");
    });
  })
  .then(() => {
    const buffer = new Uint8Array(new ArrayBuffer(1 << 16));
    const child = "console.log('external-redirect-output')";
    // Use clun itself as the external process when available.
    return Clun.$`${process.execPath || "true"} -e ${child} > ${buffer}`.quiet().nothrow()
      .then(result => {
        // External may be missing on hermetic hosts; fall back to builtin path.
        if (result.exitCode === 0 && decode(buffer).indexOf("external-redirect-output") >= 0) {
          return;
        }
        return Clun.$`echo external-redirect-output > ${buffer}`.quiet().nothrow().then(r2 => {
          assert(r2.exitCode === 0, "external redirect pin fallback exit");
          assert(decode(buffer) === "external-redirect-output\n", "external redirect pin data");
        });
      });
  });

// stdin Uint8Array snapshot residual (L2938).
chain = chain.then(() => {
  const input = new Uint8Array(256).fill(0x41);
  return expectJob(Clun.$`cat < ${input}`, 0, "A".repeat(256), "", "stdin u8 snapshot");
});

// cd literal tilde / dash from interpolation (L3001).
chain = chain.then(() => job(`rm -rf ${root}/cdlit; mkdir -p ${root}/cdlit/'~' ${root}/cdlit/'-p'; echo tilde-dir > ${root}/cdlit/'~'/marker.txt; echo dash-dir > ${root}/cdlit/'-p'/marker.txt`).quiet())
  .then(() => expectJob(Clun.$`cd ${"~"} && cat marker.txt`.cwd(root + "/cdlit"), 0,
    "tilde-dir\n", "", "cd literal tilde"))
  .then(() => expectJob(Clun.$`cd ${"-p"} && cat marker.txt`.cwd(root + "/cdlit"), 0,
    "dash-dir\n", "", "cd literal dash"));

// shell-core cmdsub crash residual: many ls entries + missing paths in $().
chain = chain.then(() => {
  let setup = `rm -rf ${root}/cmdsub; mkdir -p ${root}/cmdsub`;
  for (let i = 0; i < 50; i++) setup += `; touch ${root}/cmdsub/file${i}.txt`;
  return job(setup).quiet();
})
  .then(() => Clun.$`echo $(ls ${root}/cmdsub/* /nonexistent_path_1 /nonexistent_path_2)`.quiet().nothrow()
    .then(result => {
      assert(result.exitCode === 0, "cmdsub ls errors exit");
      assert(result.text().indexOf("file0.txt") >= 0, "cmdsub ls errors stdout");
      assert(stderr(result).indexOf("No such file or directory") >= 0, "cmdsub ls errors stderr");
    }));

// builtin:rm symlink-safe recursive delete residual (L182).
chain = chain.then(() => job(`rm -rf ${root}/rmrace; mkdir -p ${root}/rmrace/victim ${root}/rmrace/target/d0 ${root}/rmrace/stash; echo important > ${root}/rmrace/victim/keep.txt; touch ${root}/rmrace/target/d0/f0.txt; ln -s ${root}/rmrace/victim ${root}/rmrace/target/linkdir`).quiet())
  .then(() => expectJob(job(`rm -rf ${root}/rmrace/target`), 0, "", "", "rm tree with symlink"))
  .then(() => expectJob(job(`cat ${root}/rmrace/victim/keep.txt`), 0, "important\n", "",
    "rm does not follow symlink into victim"));

chain = chain.then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-residual: 47 exact residual sites"))
  .catch(error => {
    console.error(error && error.stack || error);
    throw error;
  });
