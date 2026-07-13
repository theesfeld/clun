// An unref'd timer far in the future must NOT keep the process alive: this exits
// promptly (printing only "done"); if unref were broken the harness would hang.
const t = setTimeout(() => console.log('SHOULD NOT PRINT'), 60000);
t.unref();
setImmediate(() => console.log('done'));
