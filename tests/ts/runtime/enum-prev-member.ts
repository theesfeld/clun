enum E { A = 10, B = A, C = B + 1, D }
console.log([E.A, E.B, E.C, E.D, E[10], E[12]].join(","));
