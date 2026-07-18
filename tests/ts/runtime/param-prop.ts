class C {
  constructor(public x: number, private y: string, readonly z = 3) {}
  m() { return this.x + this.y.length + this.z; }
}
const c = new C(1, "ab");
console.log(JSON.stringify({x:c.x,m:c.m(),z:c.z}))
