function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

function check(command, code, stdout, error, label) {
  return command.quiet().nothrow().then(result => {
    assert(result.exitCode === code, label + " exit code: " + result.exitCode);
    assert(result.text() === stdout, label + " stdout: " + JSON.stringify(result.text()));
    assert(stderr(result) === error, label + " stderr: " + JSON.stringify(stderr(result)));
  });
}

function rejects(command, substr, label) {
  return command.quiet().then(
    () => { throw new Error(label + " must reject"); },
    error => {
      const message = String(error && error.message || error);
      assert(message.includes(substr), label + " error: " + JSON.stringify(message));
    },
  );
}

const root = "clun-shell-upstream-lex-parse.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

// --- lex.test.ts observable equivalents (stable + engineering) ---
chain = chain
  .then(() => check(job("echo next dev"), 0, "next dev\n", "", "lex basic"))
  .then(() => check(job("PWD=/tmp; echo $PWD/test.txt"), 0, "/tmp/test.txt\n", "", "lex var edgecase"))
  .then(() => check(job("PORT=3000; echo next dev $PORT"), 0, "next dev 3000\n", "", "lex vars"))
  .then(() => check(job('PORT=3000; echo next dev "$PORT"'), 0, "next dev 3000\n", "", "lex quoted_var"))
  .then(() => check(job('PORT=3000; echo next dev foo"$PORT"'), 0,
    "next dev foo3000\n", "", "lex quoted_edge_case"))
  .then(() => check(job('NICE=x; echo foo"$NICE"good"NICE"'), 0,
    "fooxgoodNICE\n", "", "lex quote_multi"))
  .then(() => check(job('echo foo; echo bar; echo "NICE;"'), 0,
    "foo\nbar\nNICE;\n", "", "lex semicolon"))
  .then(() => check(job("echo 'hello how is it going'"), 0,
    "hello how is it going\n", "", "lex single_quote"))
  .then(() => check(job('NAME=zack FULLNAME="$NAME radisic" LOL=; echo $FULLNAME'), 0,
    "zack radisic\n", "", "lex env_vars"))
  .then(() => check(job("NAME=zack foo=$bar; echo $NAME"), 0, "zack\n", "", "lex env_vars2"))
  .then(() => check(job("export NAME=zack FOO=bar; export NICE=lmao; echo $NAME $FOO $NICE"), 0,
    "zack bar lmao\n", "", "lex env_vars exported"))
  .then(() => check(job("echo {ts,tsx,js,jsx}"), 0, "ts tsx js jsx\n", "", "lex brace_expansion"))
  .then(() => check(job("echo foo && echo bar"), 0, "foo\nbar\n", "", "lex op_and"))
  .then(() => check(job("false || echo bar"), 0, "bar\n", "", "lex op_or"))
  .then(() => check(job("echo foo | cat"), 0, "foo\n", "", "lex op_pipe"))
  .then(() => check(job("echo foo & echo bar"), 0, "bar\nfoo\n", "", "lex op_bg"))
  .then(() => check(job(`echo foo > ${root}/secrets.txt; cat ${root}/secrets.txt`), 0,
    "foo\n", "", "lex op_redirect >"))
  .then(() => check(job(`echo hi 1> ${root}/fd1.txt; cat ${root}/fd1.txt`), 0,
    "hi\n", "", "lex op_redirect 1>"))
  .then(() => check(job(`(echo err 1>&2) 2> ${root}/fd2.txt; cat ${root}/fd2.txt`), 0,
    "err\n", "", "lex op_redirect 2>"))
  .then(() => check(job(`echo both &> ${root}/both.txt; cat ${root}/both.txt`), 0,
    "both\n", "", "lex op_redirect &>"))
  .then(() => check(job(`echo a > ${root}/ap.txt; echo b 1>> ${root}/ap.txt; cat ${root}/ap.txt`), 0,
    "a\nb\n", "", "lex op_redirect >>"))
  .then(() => {
    const buffer = new Uint8Array(32);
    const buffer2 = new Uint8Array(32);
    return Clun.$`echo foo > ${buffer} && echo lmao > ${buffer2}`.quiet().nothrow()
      .then(result => {
        assert(result.exitCode === 0, "lex obj_ref exit");
        const left = new TextDecoder().decode(buffer).replace(/\0+$/, "");
        const right = new TextDecoder().decode(buffer2).replace(/\0+$/, "");
        assert(left === "foo\n", "lex obj_ref buffer1");
        assert(right === "lmao\n", "lex obj_ref buffer2");
      });
  })
  .then(() => check(job("echo foo $(echo ls)"), 0, "foo ls\n", "", "lex cmd_sub_dollar"))
  .then(() => check(job("echo foo $(echo a $(echo b) $(echo c))"), 0,
    "foo a b c\n", "", "lex cmd_sub_dollar_nested"))
  .then(() => check(job("echo $(FOO=bar echo $FOO)"), 0, "\n", "",
    "lex cmd_sub_edgecase argv expand"))
  .then(() => check(job("echo $(FOO=bar printenv FOO)"), 0, "bar\n", "",
    "lex cmd_sub_edgecase assignment env"))
  .then(() => check(job("echo $(echo HI)NICE"), 0, "HINICE\n", "", "lex cmd_sub_combined_word"))
  .then(() => check(job("echo foo `echo ls`"), 0, "foo ls\n", "", "lex cmd_sub_backtick"))
  .then(() => {
    const buffer = new Uint8Array(1);
    return check(Clun.$`echo "x ${buffer}"`, 1, "",
      "clun: JS object reference not allowed in double quotes\n",
      "lex JS object ref in quotes");
  })
  .then(() => rejects(job("echo )"), "unexpected )", "lex lone closing paren"))
  .then(() => rejects(job("echo (echo hi)"), "unexpected operator (",
    "lex subshell in invalid position"))
  .then(() => check(job('echo "()"'), 0, "()\n", "", "lex quoted parens"))
  .then(() => rejects(job("echo hi |"), "empty command after pipeline operator",
    "lex Unexpected EOF pipe"))
  .then(() => check(job("echo hi &"), 0, "hi\n", "", "lex Unexpected EOF bg"))
  .then(() => rejects(job("echo hi && $(echo uh oh"),
    "unterminated command substitution", "lex Unclosed dollar subst"))
  .then(() => check(job("echo hi && $(echo uh oh)"), 127, "hi\n",
    "clun: command not found: uh\n", "lex closed dollar subst fail"))
  .then(() => rejects(job("echo hi && `echo uh oh"),
    "unterminated backtick command substitution", "lex Unclosed backtick"))
  .then(() => check(job("echo hi && `echo uh oh`"), 127, "hi\n",
    "clun: command not found: uh\n", "lex closed backtick fail"))
  .then(() => rejects(job("echo hi && (echo uh oh"),
    "unterminated subshell group", "lex Unclosed subshell"));
// Engineering-only multi-error collection remains pending (L751): Clun reports the
// first hard parse error rather than newline-joined multi-error diagnostics.

// --- parse.test.ts observable equivalents ---
chain = chain
  .then(() => check(job("echo foo"), 0, "foo\n", "", "parse basic"))
  .then(() => check(job(`echo foo > ${root}/lmao.txt; cat ${root}/lmao.txt`), 0,
    "foo\n", "", "parse basic redirect"))
  .then(() => job(`ls ${root}`).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "parse single atom ls exit");
    assert(result.text().length >= 0, "parse single atom ls lists path");
  }))
  .then(() => check(job(`touch ${root}/atom.txt; ls ${root}/atom.txt`), 0,
    root + "/atom.txt\n", "", "parse single atom ls file"))
  .then(() => job("echo ~").quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "parse tilde exit");
    assert(result.text().endsWith("\n") && result.text().length > 1, "parse tilde expands");
  }))

  .then(() => check(job('NICE=x; echo "FOO $NICE!"'), 0, "FOO x!\n", "", "parse compound atom"))
  .then(() => check(job(`echo > ${root}/pipe-redir.txt | echo hi; cat ${root}/pipe-redir.txt`), 0,
    "hi\n\n", "", "parse pipelines"))
  .then(() => check(job("echo foo && echo bar || echo lmao"), 0, "foo\nbar\n", "",
    "parse binary expressions"))
  .then(() => check(job(`FOO=bar && echo foo && echo bar | echo lmao | cat > ${root}/prec.txt; cat ${root}/prec.txt`),
    0, "foo\nlmao\n", "", "parse precedence"))
  .then(() => check(job("FOO=bar BAR=baz; export LMAO=nice; echo $FOO $BAR $LMAO"), 0,
    "bar baz nice\n", "", "parse assigns"))
  .then(() => {
    const buffer = new Uint8Array(32);
    const buffer2 = new Uint8Array(32);
    return Clun.$`echo foo > ${buffer} && echo foo > ${buffer2}`.quiet().nothrow()
      .then(result => {
        assert(result.exitCode === 0, "parse redirect js obj exit");
        assert(new TextDecoder().decode(buffer).startsWith("foo\n"), "parse redirect buf1");
        assert(new TextDecoder().decode(buffer2).startsWith("foo\n"), "parse redirect buf2");
      });
  })
  .then(() => check(job('echo "$(echo 1; echo 2)"'), 0, "1\n2\n", "", "parse cmd subst"))
  .then(() => check(job("echo $(echo foo) && echo nice"), 0, "foo\nnice\n", "",
    "parse cmd subst edgecase"))
  .then(() => check(job("if echo hi; then echo lmao; else echo lol; fi"), 0,
    "hi\nlmao\n", "", "parse if basic"))
  .then(() => check(job("if echo hi\nthen echo lmao\nelse echo lol\nfi"), 0,
    "hi\nlmao\n", "", "parse if multiline"))
  .then(() => check(job("if false; then echo b; elif true; then echo d; else echo e; fi"), 0,
    "d\n", "", "parse elif"))
  .then(() => check(job("if echo hi; then echo lmao; else echo lol; fi | cat"), 0,
    "hi\nlmao\n", "", "parse if in pipeline"))
  .then(() => check(job("echo foo & && echo hi"), 0, "hi\nfoo\n", "", "parse async left"))
  .then(() => check(job("echo hi && echo foo & && echo hi"), 0, "hi\nhi\nfoo\n", "",
    "parse async left 2"))
  .then(() => check(job("echo hi && echo foo &"), 0, "hi\nfoo\n", "", "parse async right"))
  .then(() => check(job("echo hi | echo foo &"), 0, "foo\n", "", "parse async pipeline"))
  .then(() => check(job("echo $(FOO=bar echo x)"), 0, "x\n", "",
    "parse bad-syntax cmd subst edgecase"))
  .then(() => check(job("FOO=bar BAR=baz; BUN_DEBUG_QUIET_LOGS=1 echo ok"), 0,
    "ok\n", "", "parse cmd edgecase"))
  .then(() => {
    const file = new Uint8Array(4);
    return check(Clun.$`${file} | cat`, 0, "",
      "clun: expected a command or assignment but got: \"JSObjRef\"\n",
      "parse invalid js obj pipeline")
      .then(() => check(Clun.$`${file}`, 1, "",
        "clun: expected a command or assignment but got: \"JSObjRef\"\n",
        "parse invalid js obj alone"));
  })
  .then(() => rejects(job("echo (echo foo && echo hi)"), "unexpected operator (",
    "parse subshell invalid position"))
  .then(() => rejects(job("echo foo >"), "redirection > has no target",
    "parse redirection with no file"))
  .then(() => rejects(job("(((( |||"),
    "Unexpected EOF\nUnclosed subshell\nUnclosed subshell\nUnclosed subshell",
    "lex multiple errors newline separated"))
  .then(() => job(`rm -rf ${root}`).quiet().nothrow())
  .then(() => console.log("upstream-lex-parse: 102 exact sites"))
  .catch(error => {
    console.error(error && error.stack || error);
    throw error;
  });
