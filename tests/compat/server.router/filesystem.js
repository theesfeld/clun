const fs = require("node:fs");
const path = require("node:path");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function throws(message, callback) {
  try {
    callback();
  } catch (error) {
    assert(String(error.message).includes(message), `unexpected error: ${error.message}`);
    return;
  }
  throw new Error(`expected error containing ${message}`);
}

const router = new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_PAGES,
  fileExtensions: [".tsx"],
  style: "nextjs",
  assetPrefix: "/_next/static/",
  origin: "https://clun.sh",
});

assert(router.style === "nextjs", "style getter");
assert(router.origin === "https://clun.sh", "origin getter");
assert(router.assetPrefix === "/_next/static/", "assetPrefix getter");
assert(router.routes === router.routes, "routes getter must be cached between reloads");
assert(Object.keys(router.routes).length === 72, "complete filtered inventory");
assert(router.routes["/"] === path.join(process.env.CLUN_ROUTER_PAGES, "index.tsx"), "root route");
assert(router.routes["/files/a64"] === path.join(process.env.CLUN_ROUTER_PAGES, "files/a64.tsx"), "large inventory");
assert(router.routes["/ignored"] === undefined, "extension filtering");
assert(router.routes["/escape"] === undefined, "directory symlink filtering");

let match = router.match("/posts/hey");
assert(match.name === "/posts/hey" && match.kind === "exact", "exact precedence");
match = router.match("/posts/a%20b?hello=world&second=2");
assert(match.name === "/posts/[id]" && match.params.id === "a b", "dynamic decoding");
assert(match.pathname === "/posts/a b", "decoded pathname");
assert(match.query.id === "a b" && match.query.hello === "world" && match.query.second === "2", "query and params");
assert(match.src === "https://clun.sh/_next/static/posts/[id].tsx", "public source path");

match = router.match("https://example.com/posts/%252e%252e%252fetc?x=1");
assert(match.params.id === "%2e%2e%2fetc", "percent decoding exactly once");
assert(match.query.x === "1", "absolute URL query");
match = router.match(new Request("https://example.com/posts/request"));
assert(match.params.id === "request", "Request input");

match = router.match("/posts/hey/there");
assert(match.name === "/posts/[...rest]" && match.params.rest === "hey/there", "catch-all");
match = router.match("/optional/hey/there");
assert(match.name === "/optional/[[...parts]]" && match.params.parts === "hey/there", "optional catch-all");
match = router.match("/posts/wow/hey/there");
assert(match.name === "/posts/[...rest]", "catch-all outranks optional catch-all");

for (const input of ["/", "/index"]) {
  assert(router.match(input).name === "/", `root index alias ${input}`);
}
for (const input of ["/posts", "/posts/", "/posts/index"]) {
  assert(router.match(input).name === "/posts", `nested index alias ${input}`);
}
assert(router.match("/not-present") === null, "missing route");
assert(router.match("?").name === "/", "degenerate root query");
assert(router.match("?foo=bar").query.foo === "bar", "degenerate root query value");

const queryParts = [];
for (let index = 0; index < 3000; index++) queryParts.push(`k${index}=v${index}`);
const manyQuery = router.match(`/posts?${queryParts.join("&")}`).query;
assert(Object.keys(manyQuery).length === 3000, "bounded large query inventory");
assert(manyQuery.k0 === "v0" && manyQuery.k2999 === "v2999", "large query boundaries");

const emptyRouter = new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_EMPTY_PAGES,
  fileExtensions: [".tsx"],
  style: "nextjs",
});
assert(Object.keys(emptyRouter.routes).length === 0, "empty directory inventory");
assert(emptyRouter.match("/") === null, "empty directory match");
const defaultExtensions = new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_PAGES,
  style: "nextjs",
});
assert(defaultExtensions.match("/posts/hey").name === "/posts/hey", "default extensions");

const beforeReload = router.routes;
const newDirectory = path.join(process.env.CLUN_ROUTER_PAGES, "reload");
fs.mkdirSync(newDirectory, { recursive: true });
fs.writeFileSync(path.join(newDirectory, "index.tsx"), "export default 1;\n");
router.reload();
assert(router.routes !== beforeReload, "reload replaces cached inventory atomically");
assert(router.match("/reload").name === "/reload", "reload adds route");
fs.rmSync(newDirectory, { recursive: true });
router.reload();
assert(router.match("/reload") === null, "reload removes route");

throws("Expected dir to be a string", () => new Clun.FileSystemRouter({ style: "nextjs" }));
throws("Expected origin to be a string", () => new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_PAGES,
  style: "nextjs",
  origin: 42,
}));
throws("Only 'nextjs' style", () => new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_PAGES,
  style: "other",
}));
throws("Route is missing a closing bracket]", () => new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_INVALID_PAGES,
  fileExtensions: [".tsx"],
  style: "nextjs",
}));

console.log("filesystem.router: inventory, precedence, params, query, source paths, safety, and reload passed");
