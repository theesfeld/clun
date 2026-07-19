function App(p) { return <div id="a">{p.n}</div>; }
const el = App({n: 7});
console.log(el.type);
console.log(el.props.id);
console.log(el.props.children);
