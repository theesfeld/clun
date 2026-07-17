import document, { items, name, shared } from "./document.yaml";
import extra from "./extra.yml";
import required from "./required.cjs";

console.log(
  name,
  items.length,
  document.items === items,
  document === required,
  shared === document.copy,
  shared.value,
  extra.length,
);
