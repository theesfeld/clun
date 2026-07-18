// Complete erasable TypeScript execution strip surface (language.typescript Yes).
type Id = string;
interface Point { x: number; y: number }
declare enum Ambient { A, B }
namespace TypesOnly {
  export type N = number;
  export interface Box { v: number }
}
const n: number = 2;
const label: string = "ok";
function id<T>(value: T): T { return value; }
const arrow = <T,>(value: T): T => value;
class Cell {
  value: number;
  constructor(value: number) { this.value = value; }
  get(): number { return this.value; }
}
const cast = ("z" as unknown) as string;
const cfg = { port: 7 } satisfies Record<string, number>;
const opt = (x?: number): number => (x === undefined ? 0 : x);
const point: Point = { x: 1, y: 3 };
console.log([
  n,
  label.length,
  id(4),
  arrow(5),
  new Cell(6).get(),
  cast.length,
  cfg.port,
  opt(),
  point.x + point.y
].join(","));
