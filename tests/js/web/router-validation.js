function throws(fn) {
  try {
    fn();
    return false;
  } catch (error) {
    return error instanceof TypeError;
  }
}

console.log(
  throws(() => Clun.serve({ routes: { "/test/:123": () => new Response("bad") } })),
  throws(() => Clun.serve({ routes: { "/test/:a/:a": () => new Response("bad") } })),
  throws(() => Clun.serve({ routes: { "/test/*/tail": () => new Response("bad") } })),
  throws(() => Clun.serve({ routes: { "/test": 123 } })),
  throws(() => Clun.serve({ routes: {} })),
  throws(() => Clun.serve({ routes: { "/skip": false } })),
);

const directFile = Clun.file(`${process.cwd()}/tests/js/web/router-validation.js`);
const directFileServer = Clun.serve({ routes: { "/self": directFile } });
directFileServer.stop();
console.log(true);
