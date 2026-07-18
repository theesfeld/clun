// Phase 75 — HTMLRewriter public surface.
function caught(fn) {
  try {
    fn();
    return null;
  } catch (error) {
    return error && error.name ? error.name : String(error);
  }
}

console.log("ctor", typeof HTMLRewriter, HTMLRewriter.name);
console.log("requires-new", caught(function () { HTMLRewriter(); }));

const r1 = new HTMLRewriter().on("img", {
  element(el) {
    el.setAttribute("src", "rick.jpg");
  },
});
console.log("attr", r1.transform('<img src="cat.jpg">'));

const r2 = new HTMLRewriter().on("p", {
  element(el) {
    el.before("[");
    el.after("]");
    el.setAttribute("class", "x");
  },
});
console.log("mutate", r2.transform("<p>hi</p>"));

const r3 = new HTMLRewriter().on("div", {
  element(el) {
    el.setInnerContent("<b>n</b>", { html: true });
  },
});
console.log("inner", r3.transform("<div>old</div>"));

const r4 = new HTMLRewriter().on("span.red", {
  element(el) {
    el.setAttribute("data-ok", "1");
  },
});
console.log(
  "class-sel",
  r4.transform('<span class="red">a</span><span>b</span>').includes('data-ok="1"'),
  r4.transform('<span class="red">a</span><span>b</span>').includes("<span>b</span>"),
);

const r5 = new HTMLRewriter().on("p", {
  text(t) {
    t.replace("Z");
  },
});
console.log("text", r5.transform("<p>hello</p>"));

const r6 = new HTMLRewriter().on("script", {
  element(el) {
    el.remove();
  },
});
console.log("remove", r6.transform("<div><script>x</script></div>"));

const r7 = new HTMLRewriter().on("a", {
  element(el) {
    el.setAttribute("href", el.getAttribute("href") + "#");
  },
});
console.log("get-set", r7.transform('<a href="/x">l</a>'));

const resp = new Response("<p>y</p>");
const r8 = new HTMLRewriter().on("p", {
  element(el) {
    el.setAttribute("id", "1");
  },
});
const out = r8.transform(resp);
console.log(
  "response",
  typeof out === "object",
  out instanceof Response,
);
