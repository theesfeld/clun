function logged(target: any, key: string, desc: PropertyDescriptor) {
  const orig = desc.value;
  desc.value = function (n) {
    return orig.call(this, n) + 1;
  };
  return desc;
}
class C {
  @logged
  m(n: number): number { return n; }
}
const c = new C();
console.log(c.m(40));
