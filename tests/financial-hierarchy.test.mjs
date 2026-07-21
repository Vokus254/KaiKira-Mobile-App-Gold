import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const fixturePath = new URL("../KAIKIRA-Projektstand (14).json", import.meta.url);
const payload = JSON.parse(await readFile(fixturePath, "utf8"));
const { susa, mapping, structure } = payload.core;
const norm = value => String(value ?? "").trim().toLowerCase().normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
const account = value => String(value ?? "").trim().replace(/\.0$/, "").trim();
const pathKey = (levels, target = "") => levels.map(norm).join("||") + "##" + norm(target);
const exact = new Map();
const byTarget = new Map();
for (const row of structure) {
  exact.set(pathKey(row.levels, row.ziel), row);
  const target = norm(row.ziel);
  if (!byTarget.has(target)) byTarget.set(target, []);
  byTarget.get(target).push(row);
}
const positions = { balance: new Map(), income: new Map() };
const order = { balance: [], income: [] };
const prefixKey = (parts, depth) => parts.slice(0, depth).map(norm).join("||");
for (const row of structure) {
  const parts = row.levels.filter(Boolean);
  const top = norm(parts[0]);
  const kind = top.includes("bilanz") ? "balance" : top.includes("guv") || top.includes("gewinn") || top.includes("verlust") ? "income" : null;
  if (!kind) continue;
  for (let depth = 1; depth <= parts.length; depth += 1) {
    const key = prefixKey(parts, depth);
    if (positions[kind].has(key)) continue;
    positions[kind].set(key, { label: parts[depth - 1], depth, bj: 0, vj: 0, count: 0 });
    order[kind].push(key);
  }
}
const susaByAccount = new Map(susa.map(row => [account(row.konto), row]));
let unresolved = 0;
for (const mapRow of mapping) {
  let resolved = exact.get(pathKey(mapRow.levels, mapRow.ziel));
  if (!resolved) {
    const candidates = byTarget.get(norm(mapRow.ziel)) || [];
    if (candidates.length === 1) resolved = candidates[0];
    else {
      const deepest = [...mapRow.levels].reverse().find(Boolean);
      const matches = candidates.filter(candidate => candidate.levels.some(level => norm(level) === norm(deepest)));
      if (matches.length === 1) resolved = matches[0];
    }
  }
  const source = susaByAccount.get(account(mapRow.konto));
  if (!resolved || !source) { unresolved += 1; continue; }
  const parts = resolved.levels.filter(Boolean);
  const top = norm(parts[0]);
  const kind = top.includes("bilanz") ? "balance" : "income";
  for (let depth = 1; depth <= parts.length; depth += 1) {
    const row = positions[kind].get(prefixKey(parts, depth));
    row.bj += source.bj;
    row.vj += source.vj;
    row.count += 1;
  }
}
assert.equal(unresolved, 0, "all mapping rows must resolve exactly like core.html");
assert.equal(mapping.length, 1431);
const balance = order.balance.map(key => positions.balance.get(key));
const income = order.income.map(key => positions.income.get(key));
assert.equal(balance[0].label, "1. Bilanz");
assert.equal(income[0].label, "2. GuV");
assert.ok(Math.abs(balance[0].bj - 2124859.83) <= 0.01, "raw balance root must equal the signed annual-result difference");
assert.ok(Math.abs(income[0].bj + 2124859.83) <= 0.01, "raw P&L root must be the inverse annual result");

const anomalies = structure.filter(row => /dummy|test|platzhalter/i.test(row.levels.join(" ") + " " + row.ziel));
console.log(JSON.stringify({
  unresolved,
  balancePositionCount: balance.length,
  incomePositionCount: income.length,
  balanceTop: balance.filter(row => row.depth <= 2),
  incomeTop: income.filter(row => row.depth <= 2),
  suspiciousStructureLabels: anomalies
}, null, 2));
