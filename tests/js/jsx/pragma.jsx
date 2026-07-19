// @jsxRuntime classic
// @jsx h
// @jsxFrag Frag
function h(type, props, ...children) {
  return { type, props, children };
}
const Frag = "FRAG";
const el = <><i>x</i></>;
console.log(el.type);
console.log(el.children[0].type);
console.log(el.children[0].children[0]);
