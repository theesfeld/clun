// Phase 75 — Clun.markdown public surface (Bun.markdown-shaped).
function caught(fn) {
  try {
    fn();
    return null;
  } catch (error) {
    return error && error.name ? error.name : String(error);
  }
}

const md = Clun.markdown;
const desc = Object.getOwnPropertyDescriptor(Clun, "markdown");
console.log(
  "api",
  typeof md,
  typeof md.html,
  typeof md.render,
  typeof md.react,
  md.html.name,
  md.html.length,
  desc.enumerable,
  desc.configurable,
);

console.log("html-heading", JSON.stringify(md.html("# Hello **world**")));
console.log("html-para", JSON.stringify(md.html("hello *there*")));
console.log("html-code", JSON.stringify(md.html("`x`")));
console.log(
  "html-list",
  JSON.stringify(md.html("- a\n- b")).includes("<ul>") &&
    JSON.stringify(md.html("- a\n- b")).includes("<li>a</li>"),
);
console.log(
  "html-strike",
  JSON.stringify(md.html("~~x~~")).includes("<del>x</del>"),
);
console.log(
  "html-fence",
  JSON.stringify(md.html("```js\n1\n```")).includes("language-js"),
);

const rendered = md.render("# Title\n\nHi **bold**", {
  heading: (children, meta) => `<h${meta.level} class="t">${children}</h${meta.level}>`,
  strong: (children) => `<b>${children}</b>`,
  paragraph: (children) => `<p>${children}</p>`,
});
console.log("render", rendered.includes('class="t"'), rendered.includes("<b>bold</b>"));

const stripped = md.render("# Hello **world**", {
  heading: (c) => c,
  strong: (c) => c,
  paragraph: (c) => c,
});
console.log("strip", stripped.includes("Hello"), stripped.includes("world"), !stripped.includes("<"));

const react = md.react("# X");
console.log(
  "react",
  react && react.type === "div",
  typeof react.props.dangerouslySetInnerHTML.__html === "string",
);

console.log(
  "headings-ids",
  md.html("## Hello World", { headings: true }).includes('id="hello-world"'),
);

console.log("coercion", typeof md.html(42));
console.log("no-throw-empty", JSON.stringify(md.html("")));
