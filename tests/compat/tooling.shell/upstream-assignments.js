function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function check(job, expectedOut, label) {
  return job.quiet().nothrow().then(result => {
    assert(result.exitCode === 0, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    assert(stderr(result) === "", label + " stderr");
  });
}

const longValue = "x".repeat(1000);
let chain = Promise.resolve();

function queue(job, expectedOut, label) {
  chain = chain.then(() => check(job, expectedOut, label));
}

queue(Clun.$`FOO=bar BAR=baz | echo hi`, "hi\n", "multiple assignments");
queue(Clun.$`A=1 B=2 C=3 | echo test`, "test\n", "three assignments");
queue(Clun.$`FOO=bar | echo single`, "single\n", "single assignment");
queue(Clun.$`echo start | FOO=bar BAR=baz | echo end`, "end\n", "middle assignments");
queue(Clun.$`A=1 B=2 C=3 D=4 E=5 F=6 G=7 H=8 I=9 J=10 | echo many`, "many\n",
  "many assignments");
queue(Clun.$`EMPTY= ALSO_EMPTY= | echo empty`, "empty\n", "empty values");
queue(Clun.$`FOO="bar baz" HELLO="world test" | echo quoted`, "quoted\n", "quoted values");
queue(Clun.$`VAR='$HOME' OTHER='$(echo test)' | echo special`, "special\n",
  "single quoted syntax");
queue(Clun.$`A=1 | B=2 C=3 | echo first | D=4 | echo second | E=5 F=6 | echo third`,
  "third\n", "scattered assignments");
queue(Clun.$`FOO=bar BAR=baz | QUX=quux | true`, "", "assignments then true");
queue(Clun.$`LONG="${longValue}" | echo long`, "long\n", "long value");
queue(Clun.$`EQUATION="a=b+c" FORMULA="x=y*z" | echo math`, "math\n", "equals values");
queue(Clun.$`EMOJI="🚀" CHINESE="你好" | echo unicode`, "unicode\n", "unicode values");
queue(Clun.$`HOME_BACKUP=$HOME USER_BACKUP=$USER | echo expand`, "expand\n", "expanded values");
queue(Clun.$`A=1 | echo first && B=2 | echo second`, "first\nsecond\n", "and chain");
queue(Clun.$`false || X=fail | echo fallback`, "fallback\n", "or chain");
queue(Clun.$`VAR=$(echo FOO=bar | cat) | echo nested`, "nested\n", "nested substitution");
queue(Clun.$`PATTERN="*.txt" GLOB="[a-z]*" | echo glob`, "glob\n", "literal glob values");
queue(Clun.$`PATH_WIN="C:\\Users\\test" NEWLINE="line1\nline2" | echo escape`, "escape\n",
  "escaped values");
queue(Clun.$`echo before | A=1 B=2 | echo after`, "after\n", "assignments after command");
queue(Clun.$`A=1 | echo a | B=2 | echo b | C=3 | echo c | D=4 | echo d | E=5 | echo e`,
  "e\n", "alternating pipeline");
queue(Clun.$`RESULT=$(X=1 Y=2 echo done) | echo subshell`, "subshell\n",
  "assignment in substitution");
queue(Clun.$`A=1; B=2; C=3 | echo semicolon`, "semicolon\n", "semicolon assignments");
queue(Clun.$`_1=first _2=second _3=third | echo numeric`, "numeric\n", "numeric names");
queue(Clun.$`echo "test" | A=1 B=2 | cat`, "test\n", "assignment passthrough");
queue(Clun.$`ARR_0=a ARR_1=b | echo array`, "array\n", "array names");
queue(Clun.$`A=1 | B=2 | C=3 | D=4 | E=5 | true`, "", "assignment pipeline");
queue(Clun.$`A="hello world" B='single quotes' C=no_quotes | echo mixed`, "mixed\n",
  "mixed quotes");
queue(Clun.$`A=1 | echo fg | B=2`, "fg\n", "trailing assignment passthrough");
queue(Clun.$`echo=notecho ls=notls | echo real`, "real\n", "command-like names");
queue(Clun.$`MULTI="line1 \
    line2" | echo multiline`, "multiline\n", "continued line");
queue(Clun.$`echo A=1 | B=2 | cat`, "A=1\n", "assignment-like input");
queue(Clun.$`TEST_VAR=should_not_persist | echo $TEST_VAR`, "\n", "pipeline isolation");
queue(Clun.$`PERCENT="100%" DOLLAR="$100" | echo special_chars`, "special_chars\n",
  "percent and dollar values");
queue(Clun.$`A=1 B=2 | false | C=3 | echo continue`, "continue\n", "failed middle command");
queue(Clun.$`A=a B=b C=c D=d E=e F=f G=g H=h I=i J=j | echo singles`, "singles\n",
  "single character names");
queue(Clun.$`TAB="	" SPACE=" " | echo whitespace`, "whitespace\n", "whitespace values");
queue(Clun.$`(A=1 | echo inner) | B=2 | echo outer`, "outer\n", "grouped assignments");

chain.then(() => console.log("upstream-assignments: 76 exact sites"));
