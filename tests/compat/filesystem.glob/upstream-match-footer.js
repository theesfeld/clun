Promise.all(pendingTests).then(function () {
  console.log("upstream-match", testCount, "tests", assertions, "assertions", "failures", 0);
});
