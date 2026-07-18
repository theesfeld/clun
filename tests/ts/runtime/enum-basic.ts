enum E { A, B, C = 10, D }
const enum CE { X = 1, Y = X + 1 }
enum Mixed { A = 1, B = "b", C = 2 }
console.log(JSON.stringify({A:E.A,B:E.B,C:E.C,D:E.D,zero:E[0],ten:E[10],MixedB:Mixed.B,CEY:CE.Y}))
