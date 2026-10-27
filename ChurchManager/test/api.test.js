import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { openControl, tenantStore } from '../db.js';
import { createApp } from '../server.js';

const server = http.createServer(createApp({ control: openControl(':memory:'), tenant: tenantStore(':memory:') }));
await new Promise(r => server.listen(0, r));
const base = `http://localhost:${server.address().port}`;
function client() {
  let cookie = '';
  return async (method, path, body) => {
    const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'church-manager', cookie },
      body: body ? JSON.stringify(body) : undefined });
    const sc = res.headers.get('set-cookie'); if (sc) cookie = sc.split(';')[0].replace(/^sid=;?$/, '');
    const type = res.headers.get('content-type');
    return { status: res.status, data: type.includes('json') ? await res.json() : await res.text() };
  };
}
const call = client();   // church A's admin
const other = client();  // church B's admin
test.after(() => server.close());

test('requires sign-in; churches register themselves', async () => {
  assert.equal((await call('GET', '/api/members')).status, 401);
  assert.equal((await call('POST', '/api/signup', { church_name: 'First UMC', email: 'p@church.org', password: 'short' })).status, 400);
  assert.equal((await call('POST', '/api/signup', { church_name: '', email: 'p@church.org', password: 'long-enough-pw' })).status, 400);
  assert.equal((await call('POST', '/api/signup', { church_name: 'First UMC', conference: 'Texas', email: 'p@church.org', password: 'long-enough-pw' })).status, 200);
  assert.equal((await call('POST', '/api/signup', { church_name: 'Dup', email: 'p@church.org', password: 'long-enough-pw' })).status, 409);
  const s = (await call('GET', '/api/session')).data;
  assert.deepEqual([s.church, s.role], ['First UMC', 'admin']);
});

test('each church only sees its own data', async () => {
  await other('POST', '/api/signup', { church_name: 'Grace UMC', email: 'g@church.org', password: 'long-enough-pw' });
  assert.equal((await other('GET', '/api/members')).data.length, 0);
  assert.equal((await other('GET', '/api/funds')).data.length, 3); // its own seeded funds
  const mine = (await call('POST', '/api/members', { first_name: 'Private', last_name: 'Person' })).data;
  assert.equal((await other('GET', `/api/members/${mine.id}`)).status, 404);
  assert.equal((await other('GET', '/api/members')).data.length, 0);
  await call('DELETE', `/api/members/${mine.id}`);
});

test('roles are enforced and admins manage the team', async () => {
  assert.equal((await call('POST', '/api/users', { email: 't@church.org', password: 'temp-password-1', role: 'treasurer' })).status, 200);
  assert.equal((await call('POST', '/api/users', { email: 's@church.org', password: 'temp-password-1', role: 'secretary' })).status, 200);
  assert.equal((await call('POST', '/api/users', { email: 'bad@church.org', password: 'temp-password-1', role: 'god' })).status, 400);
  const t = client(), sec = client();
  assert.equal((await t('POST', '/api/login', { email: 't@church.org', password: 'temp-password-1' })).status, 200);
  assert.equal((await sec('POST', '/api/login', { email: 's@church.org', password: 'temp-password-1' })).status, 200);
  const m = (await call('POST', '/api/members', { first_name: 'Sam', last_name: 'Sec', notes: 'pastoral note', birthdate: '1980-01-01' })).data;
  assert.equal((await t('GET', '/api/donations')).status, 200);
  assert.equal((await t('POST', '/api/members', { first_name: 'x', last_name: 'y' })).status, 403);
  assert.equal((await t('GET', `/api/members/${m.id}`)).data.notes, undefined);   // treasurer can look up donors, not private notes
  assert.equal((await sec('GET', `/api/members/${m.id}`)).data.notes, 'pastoral note');
  assert.equal((await sec('GET', '/api/donations')).status, 403);
  assert.equal((await sec('GET', '/api/payroll-export')).status, 403);
  assert.equal((await sec('GET', '/api/users')).status, 403);
  const team = (await call('GET', '/api/users')).data;
  const admin = team.find(u => u.role === 'admin');
  assert.equal((await call('DELETE', `/api/users/${admin.id}`)).status, 400);   // cannot remove last admin
  assert.equal((await call('PUT', `/api/users/${admin.id}`, { role: 'pastor' })).status, 400);
  await call('DELETE', `/api/members/${m.id}`);
});

test('a user in two churches can switch between them', async () => {
  await other('POST', '/api/users', { email: 'p@church.org', role: 'pastor' }); // existing account, no new password needed
  const c = client();
  await c('POST', '/api/login', { email: 'p@church.org', password: 'long-enough-pw' });
  const s = (await c('GET', '/api/session')).data;
  assert.equal(s.churches.length, 2);
  const grace = s.churches.find(x => x.name === 'Grace UMC');
  assert.equal((await c('POST', '/api/switch-church', { church_id: grace.id })).status, 200);
  assert.deepEqual([(await c('GET', '/api/session')).data.church, (await c('GET', '/api/session')).data.role], ['Grace UMC', 'pastor']);
  assert.equal((await c('POST', '/api/switch-church', { church_id: 9999 })).status, 403);
});

test('login locks out after repeated failures', async () => {
  const c = client();
  for (let i = 0; i < 5; i++) assert.equal((await c('POST', '/api/login', { email: 'victim@x.org', password: 'nope-nope-nope' })).status, 401);
  assert.equal((await c('POST', '/api/login', { email: 'victim@x.org', password: 'nope-nope-nope' })).status, 429);
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
