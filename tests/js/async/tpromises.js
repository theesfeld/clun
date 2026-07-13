const tp = require('node:timers/promises');
(async () => {
  console.log('timeout', await tp.setTimeout(5, 'a'));
  console.log('immediate', await tp.setImmediate('b'));
  let count = 0;
  for await (const v of tp.setInterval(5, 'tick')) {
    console.log(v, ++count);
    if (count === 3) break;
  }
  console.log('done');
})();
