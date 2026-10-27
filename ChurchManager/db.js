import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

// Each church gets its own SQLite file (data/churches/<id>.db): hard isolation between congregations.
export function tenantStore(dir = 'data/churches') {
  const cache = new Map();
  return id => {
    if (!Number.isInteger(id)) throw new Error('bad church id');
    if (!cache.has(id)) cache.set(id, openDb(dir === ':memory:' ? ':memory:' : `${dir}/${id}.db`));
    return cache.get(id);
  };
}

// Central accounts database: churches, users, and which role each user holds in which church.
export function openControl(path = 'data/control.db') {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS churches (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, conference TEXT DEFAULT '', district TEXT DEFAULT '',
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, salt TEXT NOT NULL, hash TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS memberships (
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      church_id INTEGER NOT NULL REFERENCES churches(id) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK (role IN ('admin','pastor','treasurer','secretary','worship')),
      PRIMARY KEY (user_id, church_id));`);
  return db;
}

export function openDb(path = 'data/church.db') {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;');
  db.exec(SCHEMA);
  seedHymns(db);
  return db;
}

// Money is always stored as integer cents (*_cents columns).
const SCHEMA = `
CREATE TABLE IF NOT EXISTS members (
  id INTEGER PRIMARY KEY,
  first_name TEXT NOT NULL, last_name TEXT NOT NULL,
  email TEXT, phone TEXT, address TEXT, birthdate TEXT,
  joined_date TEXT, baptized_date TEXT,
  status TEXT NOT NULL DEFAULT 'active',      -- active | inactive | visitor | deceased
  roles TEXT DEFAULT '',                        -- comma separated: Lay Leader, Trustee, Choir...
  notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS groups (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, description TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS group_members (
  group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  member_id INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, member_id)
);
CREATE TABLE IF NOT EXISTS hymns (
  id INTEGER PRIMARY KEY, title TEXT NOT NULL, hymnal_number TEXT DEFAULT '',
  tune TEXT DEFAULT '', themes TEXT DEFAULT '', notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS services (
  id INTEGER PRIMARY KEY, date TEXT NOT NULL, title TEXT NOT NULL,
  season TEXT DEFAULT '', scripture TEXT DEFAULT '', sermon_title TEXT DEFAULT '', notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS service_items (
  id INTEGER PRIMARY KEY,
  service_id INTEGER NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  position INTEGER NOT NULL, type TEXT NOT NULL DEFAULT 'other',
  title TEXT DEFAULT '', hymn_id INTEGER REFERENCES hymns(id) ON DELETE SET NULL,
  leader TEXT DEFAULT '', notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS funds (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, restricted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS donations (
  id INTEGER PRIMARY KEY, date TEXT NOT NULL,
  member_id INTEGER REFERENCES members(id) ON DELETE SET NULL,
  fund_id INTEGER NOT NULL REFERENCES funds(id),
  amount_cents INTEGER NOT NULL, method TEXT DEFAULT 'check', note TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS expenses (
  id INTEGER PRIMARY KEY, date TEXT NOT NULL, payee TEXT NOT NULL,
  category TEXT NOT NULL, amount_cents INTEGER NOT NULL, note TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS budget_lines (
  id INTEGER PRIMARY KEY, year INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('income','expense')),
  category TEXT NOT NULL,                       -- income: a fund name; expense: an expense category
  amount_cents INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS staff (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, title TEXT DEFAULT '',
  external_id TEXT DEFAULT '',                  -- employee ID in ADP / Paychex / etc.
  pay_type TEXT NOT NULL DEFAULT 'salary',      -- salary | hourly
  rate_cents INTEGER NOT NULL DEFAULT 0,        -- per pay period (salary) or per hour (hourly)
  active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS payroll_entries (
  id INTEGER PRIMARY KEY,
  staff_id INTEGER NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  period_start TEXT NOT NULL, period_end TEXT NOT NULL,
  hours REAL NOT NULL DEFAULT 0, gross_cents INTEGER NOT NULL DEFAULT 0, note TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS weekly_stats (
  id INTEGER PRIMARY KEY, date TEXT NOT NULL UNIQUE,
  worship_attendance INTEGER NOT NULL DEFAULT 0, online_attendance INTEGER NOT NULL DEFAULT 0,
  children INTEGER NOT NULL DEFAULT 0, sunday_school INTEGER NOT NULL DEFAULT 0,
  professions_of_faith INTEGER NOT NULL DEFAULT 0, notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, date TEXT NOT NULL, title TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'community',       -- community | study | camp | outreach | other
  attendance INTEGER NOT NULL DEFAULT 0, group_id INTEGER REFERENCES groups(id) ON DELETE SET NULL,
  notes TEXT DEFAULT ''
);
`;

// Only well-known public-domain texts; add your hymnal numbers in the UI.
const SEED_HYMNS = [
  ['Amazing Grace', 'NEW BRITAIN', 'grace,assurance'],
  ['Holy, Holy, Holy! Lord God Almighty', 'NICAEA', 'trinity,praise'],
  ['Come, Thou Fount of Every Blessing', 'NETTLETON', 'grace,thanksgiving'],
  ['A Mighty Fortress Is Our God', 'EIN FESTE BURG', 'reformation,trust'],
  ['O for a Thousand Tongues to Sing', 'AZMON', 'praise,wesley'],
  ['And Can It Be That I Should Gain', 'SAGINA', 'grace,wesley'],
  ['Joy to the World', 'ANTIOCH', 'advent,christmas'],
  ['Christ the Lord Is Risen Today', 'EASTER HYMN', 'easter'],
  ['Come, Thou Long-Expected Jesus', 'STUTTGART', 'advent,wesley'],
  ['Be Thou My Vision', 'SLANE', 'devotion'],
];

function seedHymns(db) {
  if (db.prepare('SELECT COUNT(*) n FROM hymns').get().n) return;
  const ins = db.prepare('INSERT INTO hymns (title, tune, themes) VALUES (?,?,?)');
  for (const h of SEED_HYMNS) ins.run(...h);
  const fund = db.prepare('INSERT OR IGNORE INTO funds (name, restricted) VALUES (?,?)');
  fund.run('General Fund', 0); fund.run('Building Fund', 1); fund.run('Missions', 1);
}
