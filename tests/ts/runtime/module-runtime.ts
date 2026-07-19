module M {
  export let y = 2;
  export function g() { return y * 3; }
}
console.log(JSON.stringify({y:M.y,g:M.g()}))
