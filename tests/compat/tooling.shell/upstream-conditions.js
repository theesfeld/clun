function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function job(source) {
  return Clun.$`${{ raw: source }}`;
}

const root = "clun-shell-upstream-conditions.tmp";
let chain = job(`rm -rf ${root}; mkdir -p ${root}/mydir; touch ${root}/package.json ${root}/lol`).quiet();

function queue(source, expectedOut, expectedCode, label, expectedErr = "") {
  chain = chain.then(() => job(source).cwd(root).quiet().nothrow()).then(result => {
    assert(result.exitCode === expectedCode, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    assert(stderr(result) === expectedErr, label + " stderr");
  });
}

queue("[[ -f package.json ]] && echo yes!", "yes!\n", 0, "regular file");
queue("[[ -f mumbo.jumbo ]] && echo yes!", "", 1, "missing regular file");
queue("[[ -f mydir ]] && echo yes!", "", 1, "directory is not regular file");
queue("[[ -f /dev/null ]] && echo yes!", "", 1, "character device is not regular file");
queue("[[ -d mydir ]] && echo yes!", "yes!\n", 0, "directory");
queue("[[ -d mumbo.jumbo ]] && echo yes!", "", 1, "missing directory");
queue("[[ -d package.json ]] && echo yes!", "", 1, "regular file is not directory");
queue("[[ -c /dev/null ]] && echo yes!", "yes!\n", 0, "character device");
queue("[[ -c lol ]] && echo yes!", "", 1, "file is not character device");
queue("[[ -c mumbo.jumbo ]] && echo yes!", "", 1, "missing character device");

queue('FOO=""; [[ -z $FOO ]] && echo yes!', "yes!\n", 0, "empty string");
queue('[[ -z "skldjfldsf" ]] && echo yes!', "", 1, "nonempty is not zero length");
queue('FOO="lkjdflskdjf"; [[ -n $FOO ]] && echo yes!', "yes!\n", 0, "nonempty string");
queue('FOO="" [[ -n $FOO ]] && echo yes!', "", 1, "assignment prefix empty string");
queue("[[ -n hey ]] | echo hi | cat", "hi\n", 0, "condition pipeline precedence");
queue("[[ foo == foo ]] && echo yes!", "yes!\n", 0, "string equality");
queue("[[ foo == lol ]] && echo yes!", "", 1, "string equality failure");
queue("[[ foo != foo ]] && echo yes!", "", 1, "string inequality failure");
queue("[[ lmao != foo ]] && echo yes!", "yes!\n", 0, "string inequality");
queue("LOL=; [[ $LOl == $LOL ]] && echo yes!", "yes!\n", 0, "empty equality");
queue("LOL=; [[ $LOl != $LOL ]] && echo yes!", "", 1, "empty inequality");

queue("[[ foo > bar && $PWD -ef . ]]", "", 0, "ksh lexical and inode expression");
queue("[[ x ]]", "", 0, "single operand");
queue("[[ ! x ]]", "", 1, "single operand negation");
queue("[[ ! x || x ]]", "", 0, "negation precedence");
queue("[[ ! 1 -eq 1 ]]; echo $?\n[[ ! ! 1 -eq 1 ]]; echo $?", "1\n0\n", 0,
  "double negation status");
queue("[[ ! ! ! 1 -eq 1 ]]; echo $?\n[[ ! ! ! ! 1 -eq 1 ]]; echo $?", "1\n0\n", 0,
  "repeated negation status");
queue("[[ a ]]", "", 0, "plain operand");
queue("[[ (a) ]]", "", 0, "grouped operand");
queue("[[ -n a ]]", "", 0, "plain unary operand");
queue("[[ (-n a) ]]", "", 0, "grouped unary operand");
queue("[[ -n $UNSET ]]", "", 1, "unset nonempty predicate");
queue("[[ -z $UNSET ]]", "", 0, "unset empty predicate");
queue("[[ -n $UNSET && $UNSET == foo ]]", "", 1, "and short circuit false lhs");
queue("[[ -z $UNSET && $UNSET == foo ]]", "", 1, "and evaluates false rhs");
queue("[[ -z $UNSET || -d $PWD ]]", "", 0, "or short circuit true lhs");
queue("[[ -n $TDIR || -n $UNSET && $PWD -ef xyz ]]", "", 1, "and before or");
queue("[[ ( -n $TDIR || -n $UNSET ) && $PWD -ef xyz ]]", "", 1,
  "grouped precedence");

queue("unset IVAR A\n[[ 7 -gt $IVAR ]]", "", 0, "empty arithmetic rhs");
queue("unset IVAR A\n[[ $IVAR -gt 7 ]]", "", 1, "empty arithmetic lhs");
queue("IVAR=4\n[[ $IVAR -gt 7 ]]", "", 1, "arithmetic variable comparison");
queue("[[ 7 -eq 4+3 ]]", "", 0, "arithmetic expression");
queue("IVAR=4+3\n[[ $IVAR -eq 7 ]]", "", 0, "expanded arithmetic expression");
queue("unset IVAR A\n[[ $filename == *.c ]]", "", 1, "unset pattern candidate");
queue("filename=patmatch.c\n[[ $filename == *.c ]]", "", 0, "pattern candidate");

queue("shopt -s extglob\narg=-7\n[[ $arg == -+([0-9]) ]]", "", 0,
  "extended glob repeated digits");
queue("shopt -s extglob\narg=-H\n[[ $arg == -+([0-9]) ]]", "", 1,
  "extended glob repeated digits failure");
queue("shopt -s extglob\narg=+4\n[[ $arg == ++([0-9]) ]]", "", 0,
  "extended glob literal plus");
queue("STR=file.c\nPAT=\nif [[ $STR = $PAT ]]; then\n  echo oops\nfi", "", 0,
  "nonempty string does not match empty pattern");
queue("STR=\nPAT=\nif [[ $STR = $PAT ]]; then\n  echo ok\nfi", "ok\n", 0,
  "empty string matches empty pattern");
queue('if [[ "123abc" == *?(a)bc ]]; then echo ok 42; else echo bad 42; fi\n' +
  'if [[ "123abc" == *?(a)bc ]]; then echo ok 43; else echo bad 43; fi',
  "ok 42\nok 43\n", 0, "optional extended glob regression");

chain
  .then(() => job(`rm -rf ${root}`).quiet())
  .then(() => console.log("upstream-conditions: 51 exact sites"));
