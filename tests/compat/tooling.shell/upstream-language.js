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

chain = chain.then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-language: 177 exact sites"));
