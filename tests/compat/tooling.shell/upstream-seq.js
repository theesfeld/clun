function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function stderr(result) {
  return new TextDecoder().decode(result.stderr);
}

function check(job, expectedCode, expectedOut, expectedErr, label) {
  return job.quiet().nothrow().then(result => {
    assert(result.exitCode === expectedCode, label + " exit code");
    assert(result.text() === expectedOut, label + " stdout");
    assert(stderr(result) === expectedErr, label + " stderr");
  });
}

const usage = "usage: seq [-w] [-f format] [-s string] [-t string] [first [incr]] last\n";
let chain = Promise.resolve();

function queue(job, code, out, err, label) {
  chain = chain.then(() => check(job, code, out, err, label));
}

queue(Clun.$`seq`, 1, "", usage, "usage");
queue(Clun.$`seq -w`, 1, "", usage, "fixed width usage");
queue(Clun.$`seq --fixed-width`, 1, "", usage, "long fixed width usage");
queue(Clun.$`seq -s ,`, 1, "", usage, "separator usage");
queue(Clun.$`seq -t ,`, 1, "", usage, "terminator usage");
queue(Clun.$`seq -w -s , -t .`, 1, "", usage, "flags only usage");
queue(Clun.$`seq -s`, 1, "", "seq: option requires an argument -- s\n", "missing separator");
queue(Clun.$`seq -t`, 1, "", "seq: option requires an argument -- t\n", "missing terminator");
queue(Clun.$`seq 0 5`, 0, "0\n1\n2\n3\n4\n5\n", "", "ascending");
queue(Clun.$`seq 5 0`, 0, "5\n4\n3\n2\n1\n0\n", "", "descending");
queue(Clun.$`seq -s, 0 5`, 0, "0,1,2,3,4,5,", "", "inline separator");
queue(Clun.$`seq -s , 0 5`, 0, "0,1,2,3,4,5,", "", "separate separator");
queue(Clun.$`seq --separator , 0 5`, 0, "0,1,2,3,4,5,", "", "long separator");
queue(Clun.$`seq -t, 0 5`, 0, "0\n1\n2\n3\n4\n5\n,", "", "inline terminator");
queue(Clun.$`seq -t , 0 5`, 0, "0\n1\n2\n3\n4\n5\n,", "", "separate terminator");
queue(Clun.$`seq --terminator , 0 5`, 0, "0\n1\n2\n3\n4\n5\n,", "", "long terminator");
queue(Clun.$`seq -s. -t, 0 5`, 0, "0.1.2.3.4.5.,", "", "separator and terminator");
queue(Clun.$`seq 0`, 0, "1\n0\n", "", "zero");
queue(Clun.$`seq 1`, 0, "1\n", "", "one");
queue(Clun.$`seq 2`, 0, "1\n2\n", "", "two");
queue(Clun.$`seq 8 8`, 0, "8\n", "", "equal bounds");
queue(Clun.$`seq ab`, 1, "", "seq: invalid argument\n", "invalid last");
queue(Clun.$`seq 4 ab`, 1, "", "seq: invalid argument\n", "invalid second");
queue(Clun.$`seq 4 7 ba`, 1, "", "seq: invalid argument\n", "invalid third");
queue(Clun.$`seq 4 0 7`, 1, "", "seq: zero increment\n", "zero increment");
queue(Clun.$`seq 4 -2 7`, 1, "", "seq: needs positive increment\n", "wrong ascending sign");
queue(Clun.$`seq 7 2 4`, 1, "", "seq: needs negative decrement\n", "wrong descending sign");
queue(Clun.$`seq 16777216 16777218`, 0, "16777216\n", "", "f32 stalled increment");
queue(Clun.$`seq 1 0.00000001 2`, 0, "1\n", "", "f32 tiny increment");
queue(Clun.$`echo $(seq 0 5)`, 0, "0 1 2 3 4 5\n", "", "ascending substitution");
queue(Clun.$`echo $(seq 5 0)`, 0, "5 4 3 2 1 0\n", "", "descending substitution");

chain.then(() => console.log("upstream-seq: 60 exact sites"));
