const extra = {a: 1, b: 2};
const el = <div className="c" {...extra} />;
console.log(el.props.className);
console.log(el.props.a);
console.log(el.props.b);
