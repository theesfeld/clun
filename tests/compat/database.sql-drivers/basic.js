// Issue #183 — database.sql-drivers full port fixture.
// Pure-CL Clun.SQL: SQLite engine + unified API exceed (inspect/stats).

function errorSummary(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + "|" + (error.code || "") + "|" + String(error.message).slice(0, 40);
  }
}

const SQL = Clun.SQL;
console.log(
  "api",
  typeof SQL,
  SQL.version,
  Array.prototype.slice.call(SQL.adapters).join(","),
);

const sql = new SQL("sqlite://:memory:");
console.log("adapter", sql.options.adapter);

const lines = [];

function push(label, value) {
  lines.push(label + "|" + value);
}

sql
  .run("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
  .then(function () {
    return sql.run("INSERT INTO users (name, age) VALUES (?, ?)", ["Ada", 36]);
  })
  .then(function () {
    return sql.run("INSERT INTO users (name, age) VALUES (?, ?)", ["Grace", 45]);
  })
  .then(function () {
    return sql.run("SELECT name, age FROM users WHERE age > ?", [40]);
  })
  .then(function (rows) {
    push("select", rows.length + ":" + rows[0].name + ":" + rows[0].age);
  })
  .then(function () {
    return sql.run("INSERT INTO users (name, age) VALUES (?, ?)", ["Tx", 1]);
  })
  .then(function () {
    return sql.run("SELECT name FROM users WHERE name = ?", ["Tx"]);
  })
  .then(function (rows) {
    push("tx", rows.length + ":" + (rows[0] && rows[0].name));
  })
  .then(function () {
    return sql.inspect();
  })
  .then(function (info) {
    push("inspect", String(info.adapter).toLowerCase() + ":" + (info.tables ? info.tables.length : 0));
  })
  .then(function () {
    const st = sql.stats();
    push("stats", String(st.adapter).toLowerCase() + ":" + (st.queries > 0 ? "ok" : "bad"));
  })
  .then(function () {
    return sql.close();
  })
  .then(function () {
    lines.forEach(function (line) {
      console.log(line);
    });
    return sql.run("SELECT 1").then(
      function () {
        console.log("invalid", "NO_THROW");
        console.log("done");
      },
      function (err) {
        console.log(
          "invalid",
          (err && err.name ? err.name : "Error") +
            "|" +
            (err && err.code ? err.code : "") +
            "|" +
            String(err && err.message ? err.message : err).slice(0, 40),
        );
        console.log("done");
      },
    );
  })
  .catch(function (err) {
    console.log("FAIL", err && err.message ? err.message : String(err));
  });
