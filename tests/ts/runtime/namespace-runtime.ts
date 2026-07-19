namespace N {
  export const x = 1;
  export function f() { return x + 1; }
  export namespace Inner {
    export const y = 2;
  }
}
console.log(JSON.stringify({x:N.x,f:N.f(),y:N.Inner.y}))
