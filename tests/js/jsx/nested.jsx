const tree = (
  <section>
    <h1>Title</h1>
    <p>{"&lt;escaped&gt;"}</p>
  </section>
);
console.log(tree.type);
console.log(tree.props.children[0].type);
console.log(tree.props.children[0].props.children);
console.log(tree.props.children[1].props.children);
