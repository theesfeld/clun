const md = Clun.markdown;
console.log("api", typeof md, typeof md.html, typeof md.render, typeof md.ansi, typeof md.react);

const html = md.html("# Hello **world**");
console.log("html", html.includes("<h1>"), html.includes("<strong>world</strong>"), html.includes("</h1>"));

const struck = md.html("~~x~~");
console.log("strike", struck.includes("<del>x</del>"));

const table = md.html("| A | B |\n| --- | --- |\n| 1 | 2 |\n");
console.log("table", table.includes("<table>"), table.includes("<th>"), table.includes("<td>"));

const rendered = md.render("# Title\n\nHi **there**", {
  heading: (children, meta) => `<h${meta.level} class="t">${children}</h${meta.level}>`,
  strong: (children) => `<b>${children}</b>`,
  paragraph: (children) => `<p class="p">${children}</p>`,
});
console.log("render", rendered.includes('class="t"'), rendered.includes("<b>there</b>"), rendered.includes('class="p"'));

const ansi = md.ansi("# Hello\n\n**bold**");
console.log("ansi", typeof ansi, ansi.includes("Hello"), ansi.includes("bold"));

let reactErr = "NO_THROW";
try {
  md.react("# x");
} catch (error) {
  reactErr = error.name + "|" + String(error.message).includes("not implemented");
}
console.log("react", reactErr);

const ns = Object.getOwnPropertyDescriptor(Clun, "markdown");
console.log("descriptor", ns.writable, ns.enumerable, ns.configurable);
