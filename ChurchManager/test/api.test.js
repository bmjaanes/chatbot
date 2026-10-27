import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { openDb } from '../db.js';
import { createApp } from '../server.js';

const server = http.createServer(createApp(openDb(':memory:')));
await new Promise(r => server.listen(0, r));
const base = `http://localhost:${server.address().port}`;
let cookie = '';
async function call(method, path, body) {
  const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'church-manager', cookie },
    body: body ? JSON.stringify(body) : undefined });
  const sc = res.headers.get('set-cookie'); if (sc) cookie = sc.split(';')[0];
  const type = res.headers.get('content-type');
  return { status: res.status, data: type.includes('json') ? await res.json() : await res.text() };
}
test.after(() => server.close());

test('requires sign-in, then setup works', async () => {
  assert.equal((await call('GET', '/api/members')).status, 401);
  assert.equal((await call('POST', '/api/setup', { email: 'p@church.org', password: 'short' })).status, 400);
  assert.equal((await call('POST', '/api/setup', { email: 'p@church.org', password: 'long-enough-pw' })).status, 200);
  assert.equal((await call('POST', '/api/setup', { email: 'x@y.z', password: 'long-enough-pw' })).status, 403);
});

test('members, groups, distribution list', async () => {
  const a = (await call('POST', '/api/members', { first_name: 'Ann', last_name: 'Lee', email: 'ann@x.org', baptized_date: '2026-03-15' })).data;
  const b = (await call('POST', '/api/members', { first_name: 'Bo', last_name: 'Kim', email: 'bo@x.org' })).data;
  const g = (await call('POST', '/api/groups', { name: 'Evening Bible Study' })).data;
  await call('PUT', `/api/groups/${g.id}/members`, { member_ids: [a.id, b.id] });
  const e = (await call('GET', `/api/groups/${g.id}/emails`)).data;
  assert.deepEqual(e.emails.sort(), ['ann@x.org', 'bo@x.org']);
  assert.equal((await call('POST', '/api/members', { first_name: 'NoLast' })).status, 400);
});

test('worship planning with hymns', async () => {
  const hymns = (await call('GET', '/api/hymns')).data;
  const s = (await call('POST', '/api/services', { date: '2026-11-01', title: 'All Saints' })).data;
  const items = (await call('PUT', `/api/services/${s.id}/items`, { items: [
    { type: 'hymn', hymn_id: hymns[0].id }, { type: 'scripture', title: 'Psalm 34' }] })).data;
  assert.equal(items.length, 2);
  assert.equal(items[0].hymn_title, hymns[0].title);
});

test('giving, budget vs actual, statements', async () => {
  const m = (await call('GET', '/api/members')).data[0];
  const fund = (await call('GET', '/api/funds')).data.find(f => f.name === 'General Fund');
  await call('POST', '/api/donations', { date: '2026-02-01', member_id: m.id, fund_id: fund.id, amount: 100.25 });
  await call('POST', '/api/donations', { date: '2026-03-01', member_id: m.id, fund_id: fund.id, amount: 50 });
  await call('POST', '/api/expenses', { date: '2026-02-10', payee: 'Utility Co', category: 'Utilities', amount: 80.1 });
  await call('POST', '/api/budget', { year: 2026, kind: 'income', category: 'General Fund', amount: 1000 });
  await call('POST', '/api/budget', { year: 2026, kind: 'expense', category: 'Utilities', amount: 500 });
  const f = (await call('GET', '/api/reports/finance?year=2026')).data;
  assert.equal(f.totalGiving, 150.25);
  assert.equal(f.net, 70.15);
  assert.equal(f.budget.find(l => l.category === 'Utilities').remaining, 419.9);
  assert.equal((await call('GET', `/api/members/${m.id}/statement?year=2026`)).data.total, 150.25);
});

test('payroll export csv', async () => {
  const st = (await call('POST', '/api/staff', { name: 'Pat Organist', external_id: 'E100', pay_type: 'hourly', rate: 25 })).data;
  await call('POST', '/api/payroll', { staff_id: st.id, period_start: '2026-10-01', period_end: '2026-10-15', hours: 10, gross: 250 });
  const r = await call('GET', '/api/payroll-export?start=2026-10-01&end=2026-10-31');
  assert.match(r.data, /E100,Pat Organist,hourly,2026-10-01,2026-10-15,10,250\.00/);
});

test('statistics report', async () => {
  await call('POST', '/api/stats', { date: '2026-03-01', worship_attendance: 80, children: 12 });
  await call('POST', '/api/stats', { date: '2026-03-08', worship_attendance: 90, children: 8 });
  await call('POST', '/api/events', { date: '2026-03-20', title: 'Community Dinner', attendance: 40 });
  const m = (await call('GET', '/api/reports/stats?year=2026')).data.months[2];
  assert.equal(m.avgWorship, 85); assert.equal(m.avgChildren, 10);
  assert.equal(m.baptisms, 1); assert.equal(m.events, 1);
});
