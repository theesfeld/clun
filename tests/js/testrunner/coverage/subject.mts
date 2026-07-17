export function add(left: number, right: number): number {
  return left + right;
}

export function choose(value: boolean): string {
  if (value) {
    return "yes";
  }
  return "no";
}

export const unused = (): number => {
  return 99;
};
