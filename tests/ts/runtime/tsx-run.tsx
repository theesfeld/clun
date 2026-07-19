type Props = { msg: string };
function Hello(props: Props) {
  return <span>{props.msg}</span>;
}
const el = Hello({ msg: "tsx-full" });
console.log(el.type);
console.log(el.props.children);
