import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { openDb } from './db.js';

const PUBLIC = join(fileURLToPath(new URL('.', import.meta.url)), 'public');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

// Simple CRUD resources. `money` fields are dollars in the API, cents in the DB.
const RESOURCES = {
  members: { required: ['first_name', 'last_name'], table: 'members', order: 'last_name, first_name',
    fields: ['first_name', 'last_name', 'email', 'phone', 'address', 'birthdate', 'joined_date', 'baptized_date', 'status', 'roles', 'notes'] },
  groups: { required: ['name'], table: 'groups', order: 'name', fields: ['name', 'description'] },
  hymns: { required: ['title'], table: 'hymns', order: 'title', fields: ['title', 'hymnal_number', 'tune', 'themes', 'notes'] },
  services: { required: ['date', 'title'], table: 'services', order: 'date DESC', fields: ['date', 'title', 'season', 'scripture', 'sermon_title', 'notes'] },
  funds: { required: ['name'], table: 'funds', order: 'name', fields: ['name', 'restricted'] },
  donations: { required: ['date', 'fund_id', 'amount'], table: 'donations', order: 'date DESC, id DESC', money: ['amount'],
    fields: ['date', 'member_id', 'fund_id', 'amount', 'method', 'note'] },
  expenses: { required: ['date', 'payee', 'category', 'amount'], table: 'expenses', order: 'date DESC, id DESC', money: ['amount'], fields: ['date', 'payee', 'category', 'amount', 'note'] },
  budget: { required: ['year', 'kind', 'category', 'amount'], table: 'budget_lines', order: 'year DESC, kind, category', money: ['amount'], fields: ['year', 'kind', 'category', 'amount'] },
  staff: { required: ['name'], table: 'staff', order: 'name', money: ['rate'], fields: ['name', 'title', 'external_id', 'pay_type', 'rate', 'active'] },
  payroll: { required: ['staff_id', 'period_start', 'period_end'], table: 'payroll_entries', order: 'period_end DESC, id DESC', money: ['gross'],
    fields: ['staff_id', 'period_start', 'period_end', 'hours', 'gross', 'note'] },
  stats: { required: ['date'], table: 'weekly_stats', order: 'date DESC',
    fields: ['date', 'worship_attendance', 'online_attendance', 'children', 'sunday_school', 'professions_of_faith', 'notes'] },
  events: { required: ['date', 'title'], table: 'events', order: 'date DESC', fields: ['date', 'title', 'kind', 'attendance', 'group_id', 'notes'] },
};

class HttpError extends Error { constructor(status, msg) { super(msg); this.status = status; } }
const col = (r, f) => (r.money?.includes(f) ? `${f}_cents` : f);
const toCents = v => Math.round(Number(v) * 100);

function fromRow(r, row) {
  if (!row) return row;
  const out = { ...row };
  for (const f of r.money ?? []) { out[f] = row[`${f}_cents`] / 100; delete out[`${f}_cents`]; }
  return out;
}
function toValues(r, body, partial = false) {
  const cols = [], vals = [];
  for (const f of r.fields) {
    if (!(f in body)) { if (partial) continue; else if (r.required?.includes(f)) throw new HttpError(400, `${f} is required`); else continue; }
    let v = body[f];
    if (v === '') v = null;
    if (v !== null && r.money?.includes(f)) { v = toCents(v); if (!Number.isFinite(v)) throw new HttpError(400, `${f} must be a number`); }
    if (typeof v === 'boolean') v = v ? 1 : 0;
    cols.push(col(r, f)); vals.push(v);
  }
  return { cols, vals };
}

export function createApp(db) {
  const sessions = new Map();

  const hashPw = (pw, salt) => scryptSync(pw, salt, 64).toString('hex');
  const hasUsers = () => db.prepare('SELECT COUNT(*) n FROM users').get().n > 0;
  function createUser(email, pw) {
    if (!email || !pw || pw.length < 10) throw new HttpError(400, 'Email and a password of at least 10 characters are required');
    const salt = randomBytes(16).toString('hex');
    db.prepare('INSERT INTO users (email, salt, hash) VALUES (?,?,?)').run(email.toLowerCase(), salt, hashPw(pw, salt));
  }
  function login(email, pw) {
    const u = db.prepare('SELECT * FROM users WHERE email = ?').get(String(email ?? '').toLowerCase());
    const given = Buffer.from(hashPw(String(pw ?? ''), u?.salt ?? '00'), 'hex');
    if (!u || !timingSafeEqual(given, Buffer.from(u.hash, 'hex'))) throw new HttpError(401, 'Invalid email or password');
    const token = randomBytes(32).toString('hex');
    sessions.set(token, u.id);
    return token;
  }
  const cookieOf = req => /(?:^|;\s*)sid=([a-f0-9]+)/.exec(req.headers.cookie ?? '')?.[1];

  async function readBody(req) {
    let s = ''; for await (const c of req) { s += c; if (s.length > 1e6) throw new HttpError(413, 'Body too large'); }
    try { return s ? JSON.parse(s) : {}; } catch { throw new HttpError(400, 'Invalid JSON'); }
  }

  // ---- route handlers: return {json} | {csv, name} ----
  function crud(name, method, id, body) {
    const r = RESOURCES[name];
    if (method === 'GET' && !id) return db.prepare(`SELECT * FROM ${r.table} ORDER BY ${r.order}`).all().map(x => fromRow(r, x));
    if (method === 'GET') {
      const row = db.prepare(`SELECT * FROM ${r.table} WHERE id = ?`).get(id);
      if (!row) throw new HttpError(404, 'Not found');
      return fromRow(r, row);
    }
    if (method === 'POST') {
      const { cols, vals } = toValues(r, body);
      const res = db.prepare(`INSERT INTO ${r.table} (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`).run(...vals);
      return fromRow(r, db.prepare(`SELECT * FROM ${r.table} WHERE id = ?`).get(res.lastInsertRowid));
    }
    if (method === 'PUT') {
      const { cols, vals } = toValues(r, body, true);
      if (!cols.length) throw new HttpError(400, 'Nothing to update');
      const res = db.prepare(`UPDATE ${r.table} SET ${cols.map(c => `${c} = ?`).join(',')} WHERE id = ?`).run(...vals, id);
      if (!res.changes) throw new HttpError(404, 'Not found');
      return fromRow(r, db.prepare(`SELECT * FROM ${r.table} WHERE id = ?`).get(id));
    }
    if (method === 'DELETE') {
      if (!db.prepare(`DELETE FROM ${r.table} WHERE id = ?`).run(id).changes) throw new HttpError(404, 'Not found');
      return { ok: true };
    }
    throw new HttpError(405, 'Method not allowed');
  }

  const groupMembers = id => db.prepare(
    `SELECT m.* FROM members m JOIN group_members gm ON gm.member_id = m.id WHERE gm.group_id = ? ORDER BY m.last_name, m.first_name`).all(id);

  function inTx(fn) {
    db.exec('BEGIN');
    try { const r = fn(); db.exec('COMMIT'); return r; } catch (e) { db.exec('ROLLBACK'); throw e; }
  }

  function financeReport(year) {
    const y = String(year);
    const giving = db.prepare(`SELECT f.name fund, COALESCE(SUM(d.amount_cents),0) c FROM funds f
      LEFT JOIN donations d ON d.fund_id = f.id AND substr(d.date,1,4) = ? GROUP BY f.id ORDER BY f.name`).all(y);
    const spending = db.prepare(`SELECT category, SUM(amount_cents) c FROM expenses WHERE substr(date,1,4) = ? GROUP BY category`).all(y);
    const givingBy = Object.fromEntries(giving.map(g => [g.fund, g.c]));
    const spendBy = Object.fromEntries(spending.map(s => [s.category, s.c]));
    const lines = db.prepare('SELECT * FROM budget_lines WHERE year = ? ORDER BY kind, category').all(Number(year)).map(b => {
      const actual = (b.kind === 'income' ? givingBy : spendBy)[b.category] ?? 0;
      return { kind: b.kind, category: b.category, budget: b.amount_cents / 100, actual: actual / 100, remaining: (b.amount_cents - actual) / 100 };
    });
    const totalGiving = giving.reduce((a, g) => a + g.c, 0), totalSpend = spending.reduce((a, s) => a + s.c, 0);
    return { year: Number(year), giving: giving.map(g => ({ fund: g.fund, total: g.c / 100 })),
      spending: spending.map(s => ({ category: s.category, total: s.c / 100 })),
      totalGiving: totalGiving / 100, totalSpending: totalSpend / 100, net: (totalGiving - totalSpend) / 100, budget: lines };
  }

  function statsReport(year) {
    const y = String(year);
    const months = [];
    for (let m = 1; m <= 12; m++) {
      const mm = `${y}-${String(m).padStart(2, '0')}`;
      const w = db.prepare(`SELECT COUNT(*) sundays, AVG(worship_attendance) avg_worship, AVG(online_attendance) avg_online,
        AVG(children) avg_children, AVG(sunday_school) avg_sunday_school, SUM(professions_of_faith) professions
        FROM weekly_stats WHERE substr(date,1,7) = ?`).get(mm);
      const ev = db.prepare(`SELECT COUNT(*) n, COALESCE(SUM(attendance),0) att FROM events WHERE substr(date,1,7) = ?`).get(mm);
      const bap = db.prepare(`SELECT COUNT(*) n FROM members WHERE substr(baptized_date,1,7) = ?`).get(mm).n;
      const r1 = v => (v == null ? null : Math.round(v * 10) / 10);
      months.push({ month: mm, sundays: w.sundays, avgWorship: r1(w.avg_worship), avgOnline: r1(w.avg_online),
        avgChildren: r1(w.avg_children), avgSundaySchool: r1(w.avg_sunday_school), professions: w.professions ?? 0,
        baptisms: bap, events: ev.n, eventAttendance: ev.att });
    }
    const members = db.prepare(`SELECT status, COUNT(*) n FROM members GROUP BY status`).all();
    return { year: Number(year), months, membership: Object.fromEntries(members.map(m => [m.status, m.n])) };
  }

  const csvCell = v => { const s = String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const toCsv = rows => rows.map(r => r.map(csvCell).join(',')).join('\r\n') + '\r\n';

  async function route(req, url, body) {
    const parts = url.pathname.split('/').filter(Boolean).slice(1); // drop "api"
    const [a, b, c] = parts, method = req.method, num = x => (x == null ? null : Number(x));
    if (a === 'session') return { json: { authenticated: sessions.has(cookieOf(req)), needsSetup: !hasUsers() } };
    if (a === 'setup' && method === 'POST') {
      if (hasUsers()) throw new HttpError(403, 'Already set up');
      createUser(body.email, body.password);
      return { json: { ok: true }, cookie: login(body.email, body.password) };
    }
    if (a === 'login' && method === 'POST') return { json: { ok: true }, cookie: login(body.email, body.password) };
    if (a === 'logout') { sessions.delete(cookieOf(req)); return { json: { ok: true }, cookie: '' }; }
    if (!sessions.has(cookieOf(req))) throw new HttpError(401, 'Not signed in');

    if (a === 'groups' && c === 'members') {
      const gid = num(b);
      if (method === 'GET') return { json: groupMembers(gid) };
      if (method === 'PUT') return { json: inTx(() => {
        db.prepare('DELETE FROM group_members WHERE group_id = ?').run(gid);
        const ins = db.prepare('INSERT OR IGNORE INTO group_members (group_id, member_id) VALUES (?,?)');
        for (const m of body.member_ids ?? []) ins.run(gid, Number(m));
        return groupMembers(gid);
      }) };
    }
    if (a === 'groups' && c === 'emails') {
      const emails = groupMembers(num(b)).filter(m => m.email && m.status !== 'deceased').map(m => m.email);
      return { json: { count: emails.length, emails, mailto: emails.length ? `mailto:?bcc=${emails.map(encodeURIComponent).join(',')}` : '' } };
    }
    if (a === 'services' && c === 'items') {
      const sid = num(b);
      const list = () => db.prepare(`SELECT i.*, h.title hymn_title, h.hymnal_number FROM service_items i
        LEFT JOIN hymns h ON h.id = i.hymn_id WHERE service_id = ? ORDER BY position`).all(sid);
      if (method === 'GET') return { json: list() };
      if (method === 'PUT') return { json: inTx(() => {
        db.prepare('DELETE FROM service_items WHERE service_id = ?').run(sid);
        const ins = db.prepare('INSERT INTO service_items (service_id, position, type, title, hymn_id, leader, notes) VALUES (?,?,?,?,?,?,?)');
        (body.items ?? []).forEach((it, i) => ins.run(sid, i + 1, it.type || 'other', it.title ?? '', it.hymn_id || null, it.leader ?? '', it.notes ?? ''));
        return list();
      }) };
    }
    if (a === 'members' && c === 'statement') { // year-end giving statement
      const year = String(url.searchParams.get('year') ?? new Date().getFullYear());
      const m = db.prepare('SELECT * FROM members WHERE id = ?').get(num(b));
      if (!m) throw new HttpError(404, 'Not found');
      const gifts = db.prepare(`SELECT d.date, f.name fund, d.amount_cents FROM donations d JOIN funds f ON f.id = d.fund_id
        WHERE d.member_id = ? AND substr(d.date,1,4) = ? ORDER BY d.date`).all(m.id, year);
      return { json: { member: `${m.first_name} ${m.last_name}`, year: Number(year),
        gifts: gifts.map(g => ({ date: g.date, fund: g.fund, amount: g.amount_cents / 100 })),
        total: gifts.reduce((s, g) => s + g.amount_cents, 0) / 100 } };
    }
    if (a === 'reports' && b === 'finance') return { json: financeReport(url.searchParams.get('year') ?? new Date().getFullYear()) };
    if (a === 'reports' && b === 'stats') return { json: statsReport(url.searchParams.get('year') ?? new Date().getFullYear()) };
    if (a === 'payroll-export') {
      const start = url.searchParams.get('start') ?? '0000-01-01', end = url.searchParams.get('end') ?? '9999-12-31';
      const rows = db.prepare(`SELECT s.external_id, s.name, s.pay_type, p.period_start, p.period_end, p.hours, p.gross_cents
        FROM payroll_entries p JOIN staff s ON s.id = p.staff_id WHERE p.period_end >= ? AND p.period_start <= ? ORDER BY s.name, p.period_start`).all(start, end);
      return { name: 'payroll-export.csv', csv: toCsv([['Employee ID', 'Name', 'Pay Type', 'Period Start', 'Period End', 'Hours', 'Gross Pay'],
        ...rows.map(r => [r.external_id, r.name, r.pay_type, r.period_start, r.period_end, r.hours, (r.gross_cents / 100).toFixed(2)])]) };
    }
    if (a === 'members-export') {
      const rows = db.prepare('SELECT * FROM members ORDER BY last_name, first_name').all();
      return { name: 'members.csv', csv: toCsv([['First', 'Last', 'Email', 'Phone', 'Status', 'Roles', 'Joined', 'Baptized'],
        ...rows.map(r => [r.first_name, r.last_name, r.email, r.phone, r.status, r.roles, r.joined_date, r.baptized_date])]) };
    }
    if (RESOURCES[a]) return { json: crud(a, method, num(b), body) };
    throw new HttpError(404, 'Not found');
  }

  return async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const send = (status, type, data, headers = {}) => {
      res.writeHead(status, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store', ...headers });
      res.end(data);
    };
    try {
      if (url.pathname.startsWith('/api/')) {
        const body = ['POST', 'PUT'].includes(req.method) ? await readBody(req) : {};
        if (req.method !== 'GET' && req.headers['x-requested-with'] !== 'church-manager') throw new HttpError(403, 'Missing CSRF header');
        const out = await route(req, url, body);
        const headers = {};
        if (out.cookie !== undefined) headers['Set-Cookie'] = `sid=${out.cookie}; HttpOnly; SameSite=Strict; Path=/${out.cookie ? '' : '; Max-Age=0'}`;
        if (out.csv) return send(200, 'text/csv', out.csv, { ...headers, 'Content-Disposition': `attachment; filename="${out.name}"` });
        return send(200, 'application/json', JSON.stringify(out.json), headers);
      }
      const rel = normalize(url.pathname === '/' ? '/index.html' : url.pathname);
      if (rel.includes('..')) throw new HttpError(400, 'Bad path');
      const file = join(PUBLIC, rel);
      try { send(200, MIME[extname(file)] ?? 'application/octet-stream', await readFile(file)); }
      catch { throw new HttpError(404, 'Not found'); }
    } catch (e) {
      const status = e.status ?? (/constraint/i.test(e.message) ? 400 : 500);
      if (status === 500) console.error(e);
      send(status, 'application/json', JSON.stringify({ error: status === 500 ? 'Server error' : e.message }));
    }
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT ?? 3000);
  http.createServer(createApp(openDb(process.env.DB_PATH ?? 'data/church.db'))).listen(port, () => console.log(`Church Manager on http://localhost:${port}`));
}
