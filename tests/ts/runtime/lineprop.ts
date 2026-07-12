const a: number = 1;
type Ignored = string;
interface Big {
  x: number;
}
function boom(): never { throw new Error("E@6"); }
boom();
