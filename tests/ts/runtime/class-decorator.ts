function seal(ctor: any) {
  ctor.sealed = true;
  return ctor;
}
@seal
class Box {
  constructor(public v: number) {}
}
const b = new Box(7);
console.log(JSON.stringify({ v: b.v, sealed: (Box as any).sealed }));
