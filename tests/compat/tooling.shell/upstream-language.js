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

chain = chain.then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-language: 207 exact sites"));
