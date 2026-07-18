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
    assert(result.exitCode === code, label + " exit code");
    assert(result.text() === stdout, label + " stdout");
    assert(stderr(result) === error, label + " stderr");
  });
}

const root = "clun-shell-upstream-language.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}`).quiet();

let nested = "x";
for (let index = 0; index < 100; index++) nested = [nested];
chain = chain.then(() => Clun.$`echo ${nested}`.text())
  .then(output => assert(output === "x\n", "100 nested interpolation arrays"));

let tooDeep = "x";
for (let index = 0; index < 101; index++) tooDeep = [tooDeep];
let depthError = "";
try {
  Clun.$`echo ${tooDeep}`;
} catch (error) {
  depthError = error.message;
}
assert(depthError === "Shell script template arrays cannot be nested more than 100 levels deep",
  "101 nested interpolation arrays");

const escapeCases = [
  ["1 2 3", '"1 2 3"'],
  ["nice\nlmao", '"nice\nlmao"'],
  ["lol $NICE", '"lol \\$NICE"'],
  ['"hello" "lol" "nice"lkasjf;jdfla<>SKDJFLKSF',
    '"\\"hello\\" \\"lol\\" \\"nice\\"lkasjf;jdfla<>SKDJFLKSF"'],
  ["✔", "✔"],
  ["lmao=✔", '"lmao=✔"'],
  ["元気かい、兄弟", "元気かい、兄弟"],
  ["d元気かい、兄弟", "d元気かい、兄弟"],
];
for (const [value, escaped] of escapeCases) {
  assert(Clun.$.escape(value) === escaped, "escape helper " + value);
  chain = chain.then(() => Clun.$`echo ${value}`.text())
    .then(output => assert(output === value + "\n", "escape round trip " + value));
}
for (const value of ["a\tb", "a\rb", "a?b"]) {
  assert(Clun.$.escape(value) === '"' + value + '"', "quoted whitespace escape");
}
chain = chain.then(() => Clun.$`echo ${"a\tb"} ${"a?b"}`.text())
  .then(output => assert(output === "a\tb a?b\n", "tab and question interpolation"));

const url = "http://www.example.com?candy_name=M&M";
chain = chain.then(() => expectJob(Clun.$`echo url="${url}"`, 0, `url=${url}\n`, "", "url double"))
  .then(() => expectJob(Clun.$`echo url='${url}'`, 0, `url=${url}\n`, "", "url single"))
  .then(() => expectJob(Clun.$`echo url=${url}`, 0, `url=${url}\n`, "", "url plain"));

const shellVariable = "$FOO";
chain = chain.then(() => expectJob(Clun.$`FOO=bar && echo "${shellVariable}"`, 0,
  "$FOO\n", "", "variable data double"))
  .then(() => expectJob(Clun.$`FOO=bar && echo '${shellVariable}'`, 0,
    "$FOO\n", "", "variable data single"))
  .then(() => expectJob(Clun.$`FOO=bar && echo ${shellVariable}`, 0,
    "$FOO\n", "", "variable data plain"))
  .then(() => expectJob(Clun.$`${"echo hi"}`, 127, "",
    "clun: command not found: echo hi\n", "interpolation in command position"))
  .then(() => expectJob(Clun.$`${["echo", "hi"]}`, 0, "hi\n", "", "array command"));

const whatsUp = "元気かい、兄弟";
const holyMoly = "ホーリーモーリー";
chain = chain.then(() => Clun.$`echo ${whatsUp}`.text())
  .then(output => assert(output === whatsUp + "\n", "Unicode interpolation"))
  .then(() => expectJob(Clun.$`${whatsUp}=NICE; echo $${whatsUp}`, 0,
    "$元気かい、兄弟\n", "clun: command not found: 元気かい、兄弟=NICE\n",
    "Unicode variable name"))
  .then(() => Clun.$`FOO=${whatsUp}; echo $FOO`.text())
  .then(output => assert(output === whatsUp + "\n", "Unicode variable value"))
  .then(() => Clun.$`echo "${whatsUp}&&nice"${holyMoly}`.text())
  .then(output => assert(output === whatsUp + "&&nice" + holyMoly + "\n",
    "Unicode compound word"))
  .then(() => Clun.$`echo $(echo ${"ハハ"})`.text())
  .then(output => assert(output === "ハハ\n", "Unicode command substitution"))
  .then(() => job("AUTH_COOKIE_SECUREALKJAKJDLASJDKLSAJD=false; echo $AUTH_COOKIE_SECUREALKJAKJDLASJDKLSAJD").text())
  .then(output => assert(output === "false\n", "long variable name"));

for (const value of ["à", " à", "à¿", '"à¿"']) {
  chain = chain.then(() => Clun.$`echo ${value}`.text())
    .then(output => assert(output === value + "\n", "Latin-1 interpolation " + value));
}

chain = chain.then(() => expectJob(job("echo LMAO|cat"), 0, "LMAO\n", "", "compact pipe"))
  .then(() => expectJob(job("echo foo&&echo hi"), 0, "foo\nhi\n", "", "compact and"))
  .then(() => expectJob(job("echo foo||echo hi"), 0, "foo\n", "", "compact or"))
  .then(() => expectJob(job(`echo foo>${root}/compact.txt`), 0, "", "", "compact redirect"))
  .then(() => job(`cat ${root}/compact.txt`).text())
  .then(output => assert(output === "foo\n", "compact redirect file"))
  .then(() => expectJob(job("echo hifriends#lol"), 0, "hifriends#lol\n", "", "hash word"))
  .then(() => expectJob(job("echo $(echo noice)"), 0, "noice\n", "", "command substitution"))
  .then(() => expectJob(job("$(exit 0) && echo hi"), 0, "hi\n", "", "empty substitution success"))
  .then(() => expectJob(job("$(exit 1) && echo hi"), 1, "", "", "empty substitution failure"))
  .then(() => expectJob(job('FOO="" $FOO'), 0, "", "", "empty variable command"));

const home = process.env.HOME;
const tildeCases = [
  ["echo ~/Documents", home + "/Documents\n"],
  ['echo ~/Do"cu"me"nts"', home + "/Documents\n"],
  ["echo ~/LOL hi hello", home + "/LOL hi hello\n"],
  ["echo ~", home + "\n"],
  ["echo ~~", "~~\n"],
  ["echo ~ hi hello", home + " hi hello\n"],
  ['HOME="" USERPROFILE="" && echo ~ && echo ~/Documents', "\n/Documents\n"],
  ["HOME=lmao USERPROFILE=lmao && echo ~", "lmao\n"],
  ["HOME=lmao USERPROFILE=lmao && echo ~ && echo ~/Documents", "lmao\nlmao/Documents\n"],
  ["HOME=/home/user USERPROFILE=/home/user && echo ~/$(echo bin)/subdir",
    "/home/user/bin/subdir\n"],
  ["HOME=/home/user USERPROFILE=/home/user && echo ~/$(echo a)/$(echo b)/c",
    "/home/user/a/b/c\n"],
  ["HOME=/home/user USERPROFILE=/home/user && echo ~$(echo /bin)/sub",
    "/home/user/bin/sub\n"],
  ["HOME=/home/user USERPROFILE=/home/user && echo ~/$(echo bin)",
    "/home/user/bin\n"],
];
for (const [source, output] of tildeCases) {
  chain = chain.then(() => expectJob(job(source), 0, output, "", "tilde " + source));
}
chain = chain.then(() => Clun.$`echo ${"~"}/x`.text())
  .then(output => assert(output === "~/x\n", "interpolated tilde"))
  .then(() => Clun.$`echo ${"~/secret"}`.text())
  .then(output => assert(output === "~/secret\n", "interpolated tilde path"))
  .then(() => Clun.$`echo ${"a b"}~/x`.text())
  .then(output => assert(output === "a b~/x\n", "tilde after interpolation"))
  .then(() => Clun.$`echo ${"a b"}~bak`.text())
  .then(output => assert(output === "a b~bak\n", "backup suffix"));

const plainInterpolation = [
  "$", ">", "&", "|", "=", ";", "\n", "{", "}", ",", "(", ")", "\\", " ",
  "'hello'", '"hello"', "`hello`",
];
for (const value of plainInterpolation) {
  chain = chain.then(() => Clun.$`echo ${value}`.text())
    .then(output => assert(output === value.replace(/\n+$/, "") + "\n",
      "plain special interpolation " + value));
}
for (const value of ["$", "`", '"', "\\"]) {
  chain = chain.then(() => Clun.$`echo "${value}"`.text())
    .then(output => assert(output === value + "\n", "double-quoted interpolation"));
}
for (const value of ["$", '"', "`", "\\\\"]) {
  chain = chain.then(() => Clun.$`echo '${value}'`.text())
    .then(output => assert(output === value + "\n", "single-quoted interpolation"));
}
chain = chain.then(() => Clun.$`echo '${"\\"}'`.text())
  .then(output => assert(output === "\\\n", "literal backslash single quote"))
  .then(() => Clun.$`echo '${"\\\\"}'`.text())
  .then(output => assert(output === "\\\\\n", "double backslash single quote"))
  .then(() => Clun.$`echo "'\${"$"}'"`.text())
  .then(output => assert(output === "'${$}'\n", "mixed quote dollar"))
  .then(() => Clun.$`echo '"${"`"}"'`.text())
  .then(output => assert(output === '"`"\n', "mixed quote backtick"))
  .then(() => Clun.$`echo ${"hello; echo world"}`.text())
  .then(output => assert(output === "hello; echo world\n", "compound interpolation"))
  .then(() => Clun.$`echo ${"hello > world"}`.text())
  .then(output => assert(output === "hello > world\n", "redirect interpolation"))
  .then(() => Clun.$`echo ${"$(echo nested)"}`.text())
  .then(output => assert(output === "$(echo nested)\n", "substitution interpolation"))
  .then(() => Clun.$`echo ${"$HOME"} ${"|"} ${"&&"} ${";"} ${">"} ${"<"} ${"*"} ${"?"}`.text())
  .then(output => assert(output === "$HOME | && ; > < * ?\n", "mixed special interpolation"));

chain = chain.then(() => expectJob(job("echo hi hello \\\non a newline!"), 0,
  "hi hello on a newline!\n", "", "single continuation"))
  .then(() => expectJob(job("echo hi hello \\\non a newline! \\\nand \\\na few \\\nothers!"), 0,
    "hi hello on a newline! and a few others!\n", "", "many continuations"))
  .then(() => expectJob(job('echo hi hello \\\non a newline! \\\nooga"\nbooga"'), 0,
    "hi hello on a newline! ooga\nbooga\n", "", "quoted continuation"));

const backtick = String.fromCharCode(96);
const gnuQuoteCases = [
  ["echo 'foo\nbar'\necho 'foo\nbar'\necho 'foo\\\nbar'",
    "foo\nbar\nfoo\nbar\nfoo\\\nbar\n", "single-quoted multiline"],
  ['echo "foo\nbar"\necho "foo\nbar"\necho "foo\\\nbar"',
    "foo\nbar\nfoo\nbar\nfoobar\n", "double-quoted multiline"],
  ["echo " + backtick + "echo 'foo\nbar'" + backtick + "\n" +
    "echo " + backtick + "echo 'foo\nbar'" + backtick + "\n" +
    "echo " + backtick + "echo 'foo\\\nbar'" + backtick,
    "foo bar\nfoo bar\nfoobar\n", "unquoted backticks"],
  ['echo "' + backtick + "echo 'foo\nbar'" + backtick + '"\n' +
    'echo "' + backtick + "echo 'foo\nbar'" + backtick + '"\n' +
    'echo "' + backtick + "echo 'foo\\\nbar'" + backtick + '"',
    "foo\nbar\nfoo\nbar\nfoobar\n", "quoted backticks"],
  ["echo $(echo 'foo\nbar')\necho $(echo 'foo\nbar')\necho $(echo 'foo\\\nbar')",
    "foo bar\nfoo bar\nfoo\\ bar\n", "unquoted dollar substitution"],
  ['echo "$(echo \'foo\nbar\')"\necho "$(echo \'foo\nbar\')"\n' +
    'echo "$(echo \'foo\\\nbar\')"',
    "foo\nbar\nfoo\nbar\nfoo\\\nbar\n", "quoted dollar substitution"],
  ['echo "$(echo \'foo\nbar\')"\necho "$(echo \'foo\nbar\')"\n' +
    'echo "$(echo \'foo\\\nbar\')"',
    "foo\nbar\nfoo\nbar\nfoo\\\nbar\n", "repeated quoted dollar substitution"],
];
for (const [source, output, label] of gnuQuoteCases) {
  chain = chain.then(() => expectJob(job(source), 0, output, "", label));
}

// Inventory burn-down: pending bunshell sites that already execute through Clun.$
// (exact observables; clun-branded diagnostics where Bun prints "bun:").
chain = chain
  .then(async () => {
    const results = await Promise.all([
      Clun.$`echo 1`.quiet(),
      Clun.$`echo 2`.quiet(),
      Clun.$`echo 3`.quiet(),
    ]);
    const texts = results.map(result => result.text()).sort().join("");
    assert(texts === "1\n2\n3\n", "concurrent writing to stdout");
  })
  .then(() => expectJob(Clun.$`echo ${1}`, 0, "1\n", "", "js number"))
  .then(() => expectJob(Clun.$`echo ${new String("1")}`, 0, "1\n", "", "js String object"))
  .then(() => expectJob(Clun.$`echo ${true}`, 0, "true\n", "", "js bool"))
  .then(() => expectJob(Clun.$`echo ${null}`, 0, "null\n", "", "js null"))
  .then(() => expectJob(Clun.$`echo ${undefined}`, 0, "undefined\n", "", "js undefined"))
  .then(() => {
    const date = new Date("2020-01-01T00:00:00.000Z");
    return expectJob(Clun.$`echo hello ${date}`, 0, `hello ${date.toString()}\n`, "", "js Date");
  })
  .then(() => expectJob(Clun.$`echo ${BigInt("9007199254740991")}`, 0,
    "9007199254740991\n", "", "js BigInt"))
  .then(() => expectJob(Clun.$`echo ${[1, 2, 3]}`, 0, "1 2 3\n", "", "js Array"))
  .then(() => {
    const shellvar = "$FOO";
    return expectJob(Clun.$`FOO=bar && echo \\${shellvar}`, 0, "\\$FOO\n", "",
      "cannot escape js string ref");
  })
  .then(() => expectJob(Clun.$`echo $(echo hi)`.quiet(), 0, "hi\n", "", "quiet cmd subst"))
  .then(() => expectJob(Clun.$``, 0, "", "", "empty input"))
  .then(() => expectJob(Clun.$`     `, 0, "", "", "whitespace-only input"))
  .then(() => expectJob(Clun.$`
`, 0, "", "", "newline-only input"))
  .then(() => expectJob(Clun.$`echo "$(echo 1; echo 2)"`, 0, "1\n2\n", "",
    "quoted cmdsubst newlines"))
  .then(() => expectJob(Clun.$`echo $(echo 1; echo 2)`, 0, "1 2\n", "",
    "unquoted cmdsubst word split"))
  .then(() => expectJob(Clun.$`echo $(echo id)/$(echo region)`, 0, "id/region\n", "",
    "concatenated cmd substs"))
  .then(() => expectJob(Clun.$`echo $(echo hi id)/$(echo region)`, 0, "hi id/region\n", "",
    "cmd subst whitespace composition"))
  .then(() => expectJob(Clun.$`printf '%s\n' $(echo id)/$(echo region)`, 0, "id/region\n", "",
    "concatenated cmd subst single argv"))
  .then(() => expectJob(Clun.$`printf '%s\n' $(echo hi id)/$(echo region)`, 0,
    "hi\nid/region\n", "", "split cmd subst multi argv"))
  .then(() => {
    const bytes = new Uint8Array(16);
    return Clun.$`echo hello > ${bytes}`.quiet().nothrow().then(result => {
      assert(result.exitCode === 0, "redirect Uint8Array exit");
      assert(new TextDecoder().decode(bytes).replace(/\0+$/, "") === "hello\n",
        "redirect Uint8Array contents");
    });
  })
  .then(() => {
    const buffer = Buffer.alloc(16);
    return Clun.$`echo hello > ${buffer}`.quiet().nothrow().then(result => {
      assert(result.exitCode === 0, "redirect Buffer exit");
      assert(buffer.toString().replace(/\0+$/, "") === "hello\n", "redirect Buffer contents");
    });
  })
  .then(() => expectJob(Clun.$`ls *.sdfljsfsdf`.cwd(root), 1, "",
    "clun: no matches found: *.sdfljsfsdf\n", "no matches should fail"))
  .then(() => expectJob(Clun.$`FOO=*.lolwut; echo $FOO`.cwd(root), 0, "*.lolwut\n", "",
    "no matches in assignment position"))
  .then(() => expectJob(Clun.$`FOO=hi*; echo $FOO`.cwd(root), 0, "hi*\n", "",
    "trailing asterisk with no matches"))
  .then(() => job(`touch hihello hifriends`).cwd(root).quiet())
  .then(() => Clun.$`FOO=hi*; echo $FOO`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "trailing asterisk matches exit");
    const words = result.text().trim().split(/\s+/).sort();
    assert(words[0] === "hifriends" && words[1] === "hihello",
      "trailing asterisk with matches");
  }))
  .then(() => job(`touch foo.js bar.js`).cwd(root).quiet())
  .then(() => Clun.$`ls *.js`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "glob with different cwd exit");
    const words = result.text().trim().split(/\n/).sort();
    assert(words[0] === "bar.js" && words[1] === "foo.js", "glob with different cwd");
  }));

// Issue #120 shell-language burn-down: additional bunshell.test.ts sites.
const bangRun = "!".repeat(11);
chain = chain
  .then(() => job(`rm -rf ${root}; mkdir -p ${root}/sub`).quiet())
  .then(() => job(
    `touch ${root}/ax.txt ${root}/foo1.txt ${root}/foo2.txt ${root}/bar.txt ` +
    `${root}/keep.txt ${root}/other.txt ${root}/f.txt ${root}/a.txt ` +
    `${root}/sub/b.txt ${root}/sub/deep.txt ${root}/ab.txt ${root}/ac.txt ` +
    `${root}/prefix${bangRun}x.txt ${root}/prefixy.txt ${root}/keep2.txt`,
  ).quiet())
  .then(() => job(`touch ${root}/'!keep1.txt' ${root}/'a[bc].txt' ${root}/'${bangRun}keep1.txt'`).quiet())
  .then(() => expectJob(Clun.$`echo ${"**/"}*`.cwd(root), 1, "",
    "clun: no matches found: **/*\n", "injected ** does not recurse"))
  .then(() => expectJob(Clun.$`echo a${"?"}*`.cwd(root), 1, "",
    "clun: no matches found: a?*\n", "injected ? is literal"))
  .then(() => Clun.$`echo ${"!keep"}*`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "inject ! exit");
    const words = result.text().trim().split(/\s+/);
    assert(words.some(w => w.includes("!keep1.txt")), "inject ! match");
    assert(!words.includes("other.txt"), "inject ! no other");
    assert(!words.includes("keep.txt"), "inject ! no bare keep.txt");
  }))
  .then(() => Clun.$`echo a${"[bc]"}*`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "inject [] exit");
    assert(result.text().includes("a[bc].txt"), "inject [] match");
    assert(!result.text().includes("ab.txt"), "inject [] no ab");
    assert(!result.text().includes("ac.txt"), "inject [] no ac");
  }))
  .then(() => Clun.$`echo ${"foo"}*`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "foo* exit");
    assert(result.text().includes("foo1.txt") && result.text().includes("foo2.txt"), "foo*");
    assert(!result.text().includes("bar.txt"), "foo* no bar");
  }))
  .then(() => Clun.$`echo **/*.txt`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "**/* exit");
    assert(result.text().replaceAll("\\", "/").includes("sub/b.txt"), "**/* recurse");
  }))
  .then(() => Clun.$`echo prefix${bangRun}*`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "long bang exit");
    assert(result.text().includes(`prefix${bangRun}x.txt`), "long bang match");
    assert(!result.text().includes("prefixy.txt"), "long bang no prefixy");
  }))
  .then(() => Clun.$`echo ${bangRun}keep*`.cwd(root).quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "lead bang exit");
    assert(result.text().includes(`${bangRun}keep1.txt`), "lead bang match");
    assert(!result.text().includes("keep2.txt"), "lead bang no keep2");
  }))
  .then(() => expectJob(Clun.$`echo /no/such/abs/dir/for-clun/*`, 1, "",
    "clun: no matches found: /no/such/abs/dir/for-clun/*\n",
    "glob missing absolute directory"))
  .then(() => expectJob(job("{echo,a,b,c} {d,e,f}"), 0, "a b c d e f\n", "",
    "brace expansion command"))
  .then(() => expectJob(job("echo {a,b,c}"), 0, "a b c\n", "", "brace list"))
  .then(() => expectJob(job("echo a{b,c}d"), 0, "abd acd\n", "", "brace middle"))
  .then(() => expectJob(job("echo {a,b}{c,d}"), 0, "ac ad bc bd\n", "", "brace concat"))
  .then(() => expectJob(job("FOO=bar BAR=baz; echo $FOO $BAR"), 0, "bar baz\n", "",
    "expand shell vars"))
  .then(() => expectJob(job("VAR=1 && echo $VAR$VAR"), 0, "11\n", "", "shell var concat"))
  .then(() => expectJob(
    job("VAR=1 && echo Test$VAR && echo $(echo \"Test: $VAR\") ; echo CommandSub$($VAR) ; echo $ ; echo \\$VAR"),
    0, "Test1\nTest: 1\nCommandSub\n$\n$VAR\n",
    "clun: command not found: 1\n", "shell var 3"))
  .then(() => expectJob(
    job("echo $ISOVAR && ISOVAR=1 && echo $ISOVAR && printenv ISOVAR || echo undefined"),
    0, "\n1\nundefined\n", "", "shell-local not exported"))
  .then(() => expectJob(
    job("export EVAR=1 EVAR2=testing EVAR3=\"test this out\" && echo $EVAR $EVAR2 $EVAR3"),
    0, "1 testing test this out\n", "", "multiple exports"))
  .then(() => expectJob(
    job("echo $EVARX && export EVARX=1 && echo $EVARX && printenv EVARX"),
    0, "\n1\n1\n", "", "exported vars"))
  .then(async () => {
    const start = (await Clun.$`pwd`.quiet()).text().trim();
    const abs = start + "/" + root;
    return expectJob(job(`cd ${abs} && pwd && cd - && pwd`), 0,
      abs + "\n" + start + "\n", "", "cd - silent");
  })
  .then(async () => {
    const result = await Clun.$`which echo nosuch_shell_cmd_zzz`.quiet().nothrow();
    assert(result.exitCode === 1, "which exit");
    const lines = result.text().split("\n");
    assert(lines[0].length > 0 && !lines[0].includes("not found"), "which path");
    assert(lines[1] === "nosuch_shell_cmd_zzz not found", "which missing line");
  })
  .then(() => job(`mkdir -p ${root}/rmdir`).quiet())
  .then(() => expectJob(job(`rm -v ${root}/rmdir`), 1, "",
    `rm: ${root}/rmdir: Is a directory\n`, "rm directory error"))
  .then(() => job(`mkdir -p ${root}/rmtree/a; touch ${root}/rmtree/a/f`).quiet())
  .then(() => Clun.$`rm -vrf ${root}/rmtree`.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, "rm -vrf exit");
    const lines = result.text().trim().split("\n").filter(Boolean).sort();
    assert(lines.length === 3, "rm -vrf lines");
  }))
  .then(() => expectJob(
    job("if lkfjslkdjfsldf; then echo no; else echo okay here; fi"),
    0, "okay here\n", "clun: command not found: lkfjslkdjfsldf\n", "if else basic"))
  .then(() => expectJob(
    job("if lkfjslkdjfsldf; then echo no; elif sdfkjsldf; then echo no2; else echo okay here; fi"),
    0, "okay here\n",
    "clun: command not found: lkfjslkdjfsldf\nclun: command not found: sdfkjsldf\n",
    "if elif else"))
  .then(() => expectJob(
    job("if BUNISBAD; then echo not true; fi && echo bun is good"),
    0, "bun is good\n", "clun: command not found: BUNISBAD\n", "if false no else"))
  .then(() => job(`echo lol > ${root}/package.json`).quiet())
  .then(() => expectJob(
    Clun.$`if [[ -f package.json ]]; [[ -f lkdfjlskdf ]]; then echo yeah; else echo okay; echo makes sense!; fi`.cwd(root),
    0, "okay\nmakes sense!\n", "", "multi statement conditions"))
  .then(() => expectJob(job('"if"'), 127, "", "clun: command not found: if\n",
    "quoted if keyword"))
  .then(() => expectJob(job("echo lksdfjklsdjfif"), 0, "lksdfjklsdjfif\n", "",
    "if token in word"))
  .then(() => expectJob(job("echo lksdfjklsdjffi"), 0, "lksdfjklsdjffi\n", "",
    "fi token in word"))
  .then(() => expectJob(job("( ( ( ( echo HI! ) ) ) )"), 0, "HI!\n", "",
    "nested subshells"))
  .then(() => expectJob(job("(echo HELLO!; echo HELLO AGAIN!)"), 0,
    "HELLO!\nHELLO AGAIN!\n", "", "multiline subshell"))
  .then(() => expectJob(job("(exit 42)"), 42, "", "", "subshell exit"))
  .then(() => expectJob(job("(exit 42); echo hi"), 0, "hi\n", "", "subshell exit 2"))
  .then(() => expectJob(
    job("VAR1=VALUE1; VAR2=VALUE2; VAR3=VALUE3; ( echo $VAR1 $VAR2 $VAR3; VAR1=a; VAR2=b; VAR3=c; echo $VAR1 $VAR2 $VAR3 ); echo $VAR1 $VAR2 $VAR3"),
    0, "VALUE1 VALUE2 VALUE3\na b c\nVALUE1 VALUE2 VALUE3\n", "",
    "subshell env copy"))
  .then(() => expectJob(job("\\(echo hi \\)"), 127, "",
    "clun: command not found: (echo\n", "escaped subshell"))
  // Live Bun prints `(hi)` for shell source `echo \(hi\)` (backslash removes
  // operator meaning). The frozen TestBuilder stdout string is double-escaped.
  .then(() => expectJob(job("echo \\(hi\\)"), 0, "(hi)\n", "",
    "escaped parens echo"))
  .then(() => expectJob(job("{ echo a; echo b; }"), 0, "a\nb\n", "", "brace group"))
  .then(() => expectJob(job("[[ -n $UNSET && $UNSET == foo ]]; echo $?"), 0, "1\n", "",
    "cond && short-circuit"))
  .then(() => expectJob(job("[[ -z $UNSET && $UNSET == foo ]]; echo $?"), 0, "1\n", "",
    "cond z &&"))
  .then(() => expectJob(job("IVAR=4+3; [[ $IVAR -eq 7 ]]; echo $?"), 0, "0\n", "",
    "cond arithmetic -eq"))
  .then(() => expectJob(job("IVAR=7; A=7; [[ \"$IVAR\" -eq \"A\" ]]; echo $?"), 0, "0\n", "",
    "cond arithmetic name"))
  .then(() => expectJob(job("filename=foo.c; [[ $filename == *.c ]]; echo $?"), 0, "0\n", "",
    "cond glob match"))
  .then(() => expectJob(job("unset filename; [[ $filename == *.c ]]; echo $?"), 0, "1\n", "",
    "cond glob no match"))
  .then(() => expectJob(job("TDIR=/tmp; [[ $TDIR == '/usr/homes/*' ]]; echo $?"), 0, "1\n", "",
    "cond quoted pattern"))
  .then(() => {
    const buffer = Buffer.alloc(64, 0);
    return Clun.$`ls /no/such/stderr/target 2> ${buffer}`.quiet().nothrow().then(result => {
      assert(result.exitCode === 1, "stderr redirect exit");
      const text = buffer.toString().replace(/\0+$/, "");
      assert(text.includes("No such file") || text.includes("no such"),
        "stderr redirect contents");
    });
  })
  .then(() => {
    try {
      // force throw path
    } catch (_) {}
    return Clun.$`false`.nothrow().then(async () => {
      try {
        await Clun.$`false`;
        assert(false, "false should throw");
      } catch (error) {
        assert(error instanceof Error, "ShellError is Error");
        assert(error.name === "ShellError", "ShellError name");
        assert(error.exitCode === 1, "ShellError exitCode");
        assert(error.stdout instanceof Uint8Array, "ShellError stdout");
        assert(error.stderr instanceof Uint8Array, "ShellError stderr");
      }
    });
  })
  .then(() => {
    const error = new Clun.$.ShellError();
    assert(error instanceof Error, "ShellError constructor");
    assert(error.name === "ShellError", "ShellError ctor name");
  })
  .then(() => expectJob(Clun.$`echo quiet-arg`.quiet(true), 0, "quiet-arg\n", "",
    "quiet(true)"))
  .then(() => expectJob(Clun.$`echo quiet-arg`.quiet(false), 0, "quiet-arg\n", "",
    "quiet(false)"))
  .then(() => expectJob(Clun.$`echo quiet-arg`.quiet(), 0, "quiet-arg\n", "",
    "quiet()"));

chain = chain.then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-language: 280 exact sites"));
