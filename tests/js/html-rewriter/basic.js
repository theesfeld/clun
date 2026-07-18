console.log("ctor", typeof HTMLRewriter, HTMLRewriter.name);

const rewriter = new HTMLRewriter().on("img", {
  element(img) {
    img.setAttribute("alt", "x");
    img.setAttribute("src", "y.png");
  },
});
const out = rewriter.transform('<img src="a.png">');
console.log("transform", out.includes('alt="x"'), out.includes('src="y.png"'));

const wrapped = new HTMLRewriter()
  .on("p", {
    element(el) {
      el.before("<b>", { html: true });
      el.after("</b>", { html: true });
    },
  })
  .transform("<p>hi</p>");
console.log("wrap", wrapped.includes("<b><p>hi</p></b>"));

const removed = new HTMLRewriter()
  .on("script", {
    element(el) {
      el.remove();
    },
  })
  .transform("<div><script>bad()</script><span>ok</span></div>");
console.log("remove", !removed.includes("script"), removed.includes("<span>ok</span>"));

const inner = new HTMLRewriter()
  .on("div.content", {
    element(el) {
      el.setInnerContent("<em>n</em>", { html: true });
    },
  })
  .transform('<div class="content">old</div>');
console.log("inner", inner.includes("<em>n</em>"), !inner.includes("old"));

const texted = new HTMLRewriter()
  .on("p", {
    text(t) {
      if (t.lastInTextNode) t.replace("NEW");
    },
  })
  .transform("<p>OLD</p>");
console.log("text", texted.includes("NEW"), !texted.includes("OLD"));

let noNew = "NO_THROW";
try {
  HTMLRewriter();
} catch (error) {
  noNew = error.name;
}
console.log("no-new", noNew);

const resp = new HTMLRewriter()
  .on("a", {
    element(el) {
      el.setAttribute("rel", "noopener");
    },
  })
  .transform(new Response('<a href="/">x</a>'));
console.log("response", resp instanceof Response, typeof resp.text === "function");
