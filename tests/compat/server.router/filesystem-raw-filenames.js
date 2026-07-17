function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const router = new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_RAW_PAGES,
  fileExtensions: [".tsx"],
  style: "nextjs",
});
const routes = Object.keys(router.routes);
assert(routes.length === 3, `expected 3 raw-byte routes, got ${routes.length}`);
assert(routes.includes("/ab"), "valid sibling was lost beside raw-byte filenames");

console.log("filesystem.router: raw POSIX filename inventory passed");
