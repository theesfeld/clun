const el = <><span/><b>ok</b></>;
console.log(el.type === Symbol.for("react.fragment"));
console.log(el.props.children.length);
console.log(el.props.children[1].props.children);
