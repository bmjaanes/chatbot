import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { openControl, openDb, tenantStore } from './db.js';

const PUBLIC = join(fileURLToPath(new URL('.', import.meta.url)), 'public');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml' };

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

const ALL = ['admin', 'pastor', 'treasurer', 'secretary', 'worship'];
const ROLES = new Set(ALL);
const PEOPLE = ['admin', 'pastor', 'secretary'], MONEY = ['admin', 'pastor', 'treasurer'], PAY = ['admin', 'treasurer'];
// Who may read / write each area. Enforced on the server for every request.
const ACCESS = {
  members: { r: ALL, w: PEOPLE }, groups: { r: [...PEOPLE, 'worship'], w: PEOPLE },
  hymns: { r: ALL, w: [...PEOPLE.slice(0, 2), 'worship'] }, services: { r: ALL, w: ['admin', 'pastor', 'worship'] },
  funds: { r: MONEY, w: MONEY }, donations: { r: MONEY, w: MONEY }, expenses: { r: MONEY, w: MONEY }, budget: { r: MONEY, w: MONEY },
  finance: { r: MONEY, w: MONEY }, staff: { r: PAY, w: PAY }, payroll: { r: PAY, w: PAY },
  stats: { r: ALL, w: PEOPLE }, events: { r: ALL, w: PEOPLE },
};
const PASTORAL = PEOPLE; // roles that may see private member fields (notes)

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

export function createApp({ control, tenant }) {
  const sessions = new Map(); // token -> { userId, email, churchId, churchName, role }
  const failures = new Map(); // email -> { n, until } : basic brute-force lockout

  const hashPw = (pw, salt) => scryptSync(pw, salt, 64).toString('hex');
  function checkPw(pw) { if (typeof pw !== 'string' || pw.length < 10) throw new HttpError(400, 'Password must be at least 10 characters'); }
  function newUser(email, pw) {
    const e = String(email ?? '').trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) throw new HttpError(400, 'A valid email is required');
    checkPw(pw);
    const salt = randomBytes(16).toString('hex');
    return Number(control.prepare('INSERT INTO users (email, salt, hash) VALUES (?,?,?)').run(e, salt, hashPw(pw, salt)).lastInsertRowid);
  }
  const churchesOf = uid => control.prepare(`SELECT c.id, c.name, m.role FROM memberships m JOIN churches c ON c.id = m.church_id
    WHERE m.user_id = ? ORDER BY c.name`).all(uid);
  function startSession(user, churchId) {
    const list = churchesOf(user.id);
    const c = list.find(x => x.id === churchId) ?? list[0];
    if (!c) throw new HttpError(403, 'This account does not belong to any church');
    const token = randomBytes(32).toString('hex');
    sessions.set(token, { userId: user.id, email: user.email, churchId: c.id, churchName: c.name, role: c.role });
    return token;
  }
  function login(email, pw) {
    const e = String(email ?? '').trim().toLowerCase(), f = failures.get(e);
    if (f?.until > Date.now()) throw new HttpError(429, 'Too many attempts. Try again in a few minutes.');
    const u = control.prepare('SELECT * FROM users WHERE email = ?').get(e);
    const given = Buffer.from(hashPw(String(pw ?? ''), u?.salt ?? '00'), 'hex');
    if (!u || !timingSafeEqual(given, Buffer.from(u.hash, 'hex'))) {
      const n = (f?.n ?? 0) + 1; failures.set(e, { n, until: n >= 5 ? Date.now() + 15 * 60_000 : 0 });
      throw new HttpError(401, 'Invalid email or password');
    }
    failures.delete(e);
    return startSession(u);
  }
  const cookieOf = req => /(?:^|;\s*)sid=([a-f0-9]+)/.exec(req.headers.cookie ?? '')?.[1];

  async function readBody(req) {
    let s = ''; for await (const c of req) { s += c; if (s.length > 1e6) throw new HttpError(413, 'Body too large'); }
    try { return s ? JSON.parse(s) : {}; } catch { throw new HttpError(400, 'Invalid JSON'); }
  }

  // ---- route handlers: return {json} | {csv, name} ----
  const bind = db => {
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

  return { crud, groupMembers, inTx, financeReport, statsReport };
  };

  const csvCell = v => { const s = String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const toCsv = rows => rows.map(r => r.map(csvCell).join(',')).join('\r\n') + '\r\n';

  function team(churchId) {
    return control.prepare(`SELECT u.id, u.email, m.role FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.church_id = ? ORDER BY u.email`).all(churchId);
  }

  async function route(req, url, body) {
    const parts = url.pathname.split('/').filter(Boolean).slice(1); // drop "api"
    const [a, b, c] = parts, method = req.method, num = x => (x == null ? null : Number(x));
    const sess = sessions.get(cookieOf(req));
    if (a === 'session') return { json: sess ? { authenticated: true, email: sess.email, church: sess.churchName, role: sess.role, churches: churchesOf(sess.userId) } : { authenticated: false } };
    if (a === 'signup' && method === 'POST') { // registers a new church and its first admin
      const name = String(body.church_name ?? '').trim();
      if (!name) throw new HttpError(400, 'Church name is required');
      const email = String(body.email ?? '').trim().toLowerCase();
      if (control.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) throw new HttpError(409, 'That email already has an account. Sign in, then ask to be added to your church.');
      control.exec('BEGIN');
      let user, cid;
      try {
        const uid = newUser(email, body.password);
        cid = Number(control.prepare('INSERT INTO churches (name, conference, district) VALUES (?,?,?)').run(name, body.conference ?? '', body.district ?? '').lastInsertRowid);
        control.prepare('INSERT INTO memberships (user_id, church_id, role) VALUES (?,?,?)').run(uid, cid, 'admin');
        control.exec('COMMIT'); user = { id: uid, email };
      } catch (e) { control.exec('ROLLBACK'); throw e; }
      tenant(cid);
      return { json: { ok: true }, cookie: startSession(user, cid) };
    }
    if (a === 'login' && method === 'POST') return { json: { ok: true }, cookie: login(body.email, body.password) };
    if (a === 'logout') { sessions.delete(cookieOf(req)); return { json: { ok: true }, cookie: '' }; }
    if (!sess) throw new HttpError(401, 'Not signed in');

    if (a === 'switch-church' && method === 'POST') {
      const token = startSession({ id: sess.userId, email: sess.email }, Number(body.church_id));
      if (sessions.get(token).churchId !== Number(body.church_id)) { sessions.delete(token); throw new HttpError(403, 'Not a member of that church'); }
      sessions.delete(cookieOf(req));
      return { json: { ok: true }, cookie: token };
    }
    if (a === 'users') { // team management: admins only
      if (sess.role !== 'admin') throw new HttpError(403, 'Only an admin can manage the team');
      const adminCount = () => control.prepare("SELECT COUNT(*) n FROM memberships WHERE church_id = ? AND role = 'admin'").get(sess.churchId).n;
      if (method === 'GET') return { json: team(sess.churchId) };
      if (method === 'POST') {
        if (!ROLES.has(body.role)) throw new HttpError(400, 'Unknown role');
        const email = String(body.email ?? '').trim().toLowerCase();
        let u = control.prepare('SELECT id FROM users WHERE email = ?').get(email);
        const uid = u ? u.id : newUser(email, body.password); // new people get the temporary password the admin chose
        control.prepare('INSERT OR REPLACE INTO memberships (user_id, church_id, role) VALUES (?,?,?)').run(uid, sess.churchId, body.role);
        return { json: team(sess.churchId) };
      }
      const target = num(b);
      if (method === 'PUT' || method === 'DELETE') {
        const cur = control.prepare('SELECT role FROM memberships WHERE user_id = ? AND church_id = ?').get(target, sess.churchId);
        if (!cur) throw new HttpError(404, 'Not found');
        if (cur.role === 'admin' && adminCount() <= 1 && (method === 'DELETE' || body.role !== 'admin')) throw new HttpError(400, 'A church needs at least one admin');
        if (method === 'DELETE') control.prepare('DELETE FROM memberships WHERE user_id = ? AND church_id = ?').run(target, sess.churchId);
        else {
          if (!ROLES.has(body.role)) throw new HttpError(400, 'Unknown role');
          control.prepare('UPDATE memberships SET role = ? WHERE user_id = ? AND church_id = ?').run(body.role, target, sess.churchId);
        }
        return { json: team(sess.churchId) };
      }
      throw new HttpError(405, 'Method not allowed');
    }

    // ---- everything below is church data: pick the area, check the role, then use THIS church's database ----
    const area = a === 'reports' ? (b === 'finance' ? 'finance' : 'stats')
      : a === 'payroll-export' ? 'payroll' : a === 'members-export' ? 'members'
      : a === 'members' && c === 'statement' ? 'finance' : a;
    const rule = ACCESS[area];
    if (!rule) throw new HttpError(404, 'Not found');
    const writes = method !== 'GET' && !(a === 'groups' && c === 'emails');
    if (!(writes ? rule.w : rule.r).includes(sess.role)) throw new HttpError(403, 'Your role does not allow this');
    const db = tenant(sess.churchId);
    const { crud, groupMembers, inTx, financeReport, statsReport } = bind(db);

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
    if (RESOURCES[a]) {
      const out = crud(a, method, num(b), body);
      if (a === 'members' && !PASTORAL.includes(sess.role)) for (const m of [].concat(out)) { delete m.notes; delete m.birthdate; delete m.address; }
      return { json: out };
    }
    throw new HttpError(404, 'Not found');
  }

  return async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const send = (status, type, data, headers = {}) => {
      res.writeHead(status, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store', ...headers });
      res.end(data);
    };
    try {
      if (url.pathname === '/healthz') return send(200, 'text/plain', 'ok');
      if (url.pathname.startsWith('/api/')) {
        const body = ['POST', 'PUT'].includes(req.method) ? await readBody(req) : {};
        if (req.method !== 'GET' && req.headers['x-requested-with'] !== 'church-manager') throw new HttpError(403, 'Missing CSRF header');
        const out = await route(req, url, body);
        const headers = {};
        // Secure flag whenever the request arrived over HTTPS (directly or via the host's proxy).
        const secure = req.headers['x-forwarded-proto'] === 'https' || process.env.COOKIE_SECURE === '1' ? '; Secure' : '';
        if (out.cookie !== undefined) headers['Set-Cookie'] = `sid=${out.cookie}; HttpOnly; SameSite=Strict; Path=/${secure}${out.cookie ? '' : '; Max-Age=0'}`;
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
  const port = Number(process.env.PORT ?? 3000), dataDir = process.env.DATA_DIR ?? 'data';
  http.createServer(createApp({ control: openControl(process.env.CONTROL_DB ?? `${dataDir}/control.db`), tenant: tenantStore(process.env.TENANT_DIR ?? `${dataDir}/churches`) })).listen(port, () => console.log(`Church Manager on http://localhost:${port}`));
}
