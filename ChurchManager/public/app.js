// Church Manager front end. DOM is built with h() / textContent only, so user-entered text is never parsed as HTML.
const $app = document.getElementById('app');

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(kid));
  return el;
}

async function api(method, path, body) {
  const res = await fetch('/api/' + path, {
    method, headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'church-manager' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && path !== 'login') { boot(); throw new Error('Signed out'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error ?? res.statusText);
  return data;
}
const money = n => (n ?? 0).toLocaleString(undefined, { style: 'currency', currency: 'USD' });
const today = () => new Date().toISOString().slice(0, 10);
const thisYear = () => new Date().getFullYear();

// ---------- generic list + form ----------
// fields: {name, label, type: text|date|number|money|select|textarea|check, options, required}
function crudView(resource, columns, fields, { lookups = {}, extraActions } = {}) {
  const root = h('div');
  let rows = [], editing = null, filter = '';
  const err = h('div', { class: 'err' });

  async function load() {
    const needed = Object.keys(lookups);
    const loaded = await Promise.all([api('GET', resource), ...needed.map(k => api('GET', lookups[k]))]);
    rows = loaded[0];
    needed.forEach((k, i) => { lookups[k + 'Rows'] = loaded[i + 1]; });
    render();
  }
  const optionsFor = f => typeof f.options === 'function' ? f.options(lookups) : f.options;

  function cell(row, c) {
    const v = typeof c.get === 'function' ? c.get(row, lookups) : row[c.key];
    return h('td', { class: c.type === 'money' || c.type === 'num' ? 'num' : '' }, c.type === 'money' ? money(v) : v ?? '');
  }

  function form() {
    const data = editing === 'new' ? {} : editing;
    const inputs = {};
    const grid = h('div', { class: 'grid' }, fields.map(f => {
      let input;
      const val = data[f.name] ?? f.default ?? (f.type === 'date' ? '' : '');
      if (f.type === 'select') {
        input = h('select', {}, h('option', { value: '' }, '—'), optionsFor(f).map(([v, l]) => h('option', { value: v, selected: String(v) === String(val) }, l)));
      } else if (f.type === 'textarea') input = h('textarea', { rows: 2 }, val);
      else if (f.type === 'check') input = h('input', { type: 'checkbox', checked: !!val });
      else input = h('input', { type: f.type === 'money' ? 'number' : f.type ?? 'text', step: f.type === 'money' ? '0.01' : f.type === 'number' ? 'any' : null, value: val, required: !!f.required });
      inputs[f.name] = input;
      return h('div', {}, h('label', {}, f.label), input);
    }));
    return h('form', { class: 'card', onsubmit: async e => {
      e.preventDefault(); err.textContent = '';
      const body = {};
      for (const f of fields) {
        const el = inputs[f.name];
        body[f.name] = f.type === 'check' ? el.checked : el.value;
        if (['number', 'money', 'select'].includes(f.type) && body[f.name] !== '' && f.type !== 'select') body[f.name] = Number(body[f.name]);
        if (f.type === 'select' && body[f.name] !== '' && /^\d+$/.test(body[f.name])) body[f.name] = Number(body[f.name]);
      }
      try {
        await (editing === 'new' ? api('POST', resource, body) : api('PUT', `${resource}/${editing.id}`, body));
        editing = null; await load();
      } catch (ex) { err.textContent = ex.message; }
    } }, grid, err,
      h('div', { class: 'bar' }, h('button', { class: 'btn', type: 'submit' }, 'Save'),
        h('button', { class: 'btn ghost', type: 'button', onclick: () => { editing = null; render(); } }, 'Cancel')));
  }

  function render() {
    const shown = rows.filter(r => !filter || JSON.stringify(Object.values(r)).toLowerCase().includes(filter.toLowerCase()));
    root.replaceChildren(
      h('div', { class: 'bar' },
        h('input', { class: 'grow', placeholder: 'Search…', value: filter, oninput: e => { filter = e.target.value; render(); const i = root.querySelector('input'); i.focus(); i.setSelectionRange(filter.length, filter.length); } }),
        extraActions?.(rows),
        h('button', { class: 'btn', onclick: () => { editing = 'new'; render(); } }, '+ Add')),
      editing ? form() : null,
      h('table', {}, h('thead', {}, h('tr', {}, columns.map(c => h('th', { class: c.type === 'money' || c.type === 'num' ? 'num' : '' }, c.label)), h('th'))),
        h('tbody', {}, shown.map(r => h('tr', {}, columns.map(c => cell(r, c)),
          h('td', {}, h('button', { class: 'link', onclick: () => { editing = r; render(); scrollTo(0, 0); } }, 'Edit'),
            h('button', { class: 'link', onclick: async () => {
              if (!confirm('Delete this record?')) return;
              try { await api('DELETE', `${resource}/${r.id}`); await load(); } catch (ex) { alert(ex.message); }
            } }, 'Delete')))))),
      shown.length ? null : h('p', { class: 'muted' }, 'Nothing here yet.'));
  }
  load();
  return root;
}

const opts = (rows, label) => (rows ?? []).map(r => [r.id, label(r)]);
const personName = m => `${m.last_name}, ${m.first_name}`;
const MEMBER_STATUS = [['active', 'Active'], ['inactive', 'Inactive'], ['visitor', 'Visitor'], ['deceased', 'Deceased']];

// ---------- sections ----------
function tabbed(title, subtitle, tabs) {
  const body = h('div'), bar = h('div', { class: 'tabs' });
  const show = i => { [...bar.children].forEach((b, j) => b.classList.toggle('on', i === j)); body.replaceChildren(tabs[i][1]()); };
  tabs.forEach(([name], i) => bar.append(h('button', { onclick: () => show(i) }, name)));
  show(0);
  return h('div', {}, h('h2', {}, title), h('div', { class: 'muted' }, subtitle), bar, body);
}

const members = () => tabbed('People', 'Members, visitors and the roles they hold', [
  ['Members', () => crudView('members',
    [{ label: 'Name', get: r => personName(r) }, { label: 'Email', key: 'email' }, { label: 'Phone', key: 'phone' }, { label: 'Status', key: 'status' }, { label: 'Roles', key: 'roles' }],
    [{ name: 'first_name', label: 'First name', required: true }, { name: 'last_name', label: 'Last name', required: true },
      { name: 'email', label: 'Email', type: 'email' }, { name: 'phone', label: 'Phone' }, { name: 'address', label: 'Address' },
      { name: 'birthdate', label: 'Birthdate', type: 'date' }, { name: 'joined_date', label: 'Joined', type: 'date' }, { name: 'baptized_date', label: 'Baptized', type: 'date' },
      { name: 'status', label: 'Status', type: 'select', options: MEMBER_STATUS, default: 'active' },
      { name: 'roles', label: 'Roles (comma separated)' }, { name: 'notes', label: 'Notes', type: 'textarea' }],
    { extraActions: () => h('a', { class: 'btn ghost', style: 'text-decoration:none', href: '/api/members-export' }, 'Export CSV') })],
  ['Distribution lists', groups],
]);

function groups() {
  const root = h('div');
  async function load() {
    const [gs, ms] = await Promise.all([api('GET', 'groups'), api('GET', 'members')]);
    root.replaceChildren(
      h('p', { class: 'muted' }, 'Create lists such as “Evening Bible Study” or “Summer Camp parents”, then copy the emails or open them in your mail app.'),
      crudView('groups', [{ label: 'Name', key: 'name' }, { label: 'Description', key: 'description' }],
        [{ name: 'name', label: 'Name', required: true }, { name: 'description', label: 'Description' }]),
      h('h3', {}, 'Manage list members'), gs.length ? null : h('p', { class: 'muted' }, 'Add a list above first.'),
      ...gs.map(g => groupEditor(g, ms)));
  }
  load();
  return root;
}

function groupEditor(g, allMembers) {
  const box = h('details', { class: 'card' }, h('summary', {}, g.name));
  box.addEventListener('toggle', async () => {
    if (!box.open || box.dataset.ready) return;
    box.dataset.ready = 1;
    const current = new Set((await api('GET', `groups/${g.id}/members`)).map(m => m.id));
    const checks = allMembers.filter(m => m.status !== 'deceased').map(m => h('label', {}, h('input', { type: 'checkbox', value: m.id, checked: current.has(m.id) }), `${personName(m)}${m.email ? '' : ' (no email)'}`));
    const out = h('div', { class: 'muted' });
    box.append(h('div', { class: 'checks' }, checks), out, h('div', { class: 'bar' },
      h('button', { class: 'btn', onclick: async () => {
        const ids = checks.map(l => l.firstChild).filter(i => i.checked).map(i => Number(i.value));
        await api('PUT', `groups/${g.id}/members`, { member_ids: ids }); out.textContent = `Saved ${ids.length} members.`;
      } }, 'Save members'),
      h('button', { class: 'btn ghost', onclick: async () => {
        const r = await api('GET', `groups/${g.id}/emails`);
        out.replaceChildren(`${r.count} email addresses: `, h('code', {}, r.emails.join(', ')), ' ', r.mailto ? h('a', { href: r.mailto }, 'Open in mail app') : '');
      } }, 'Get emails')));
  });
  return box;
}

const worship = () => tabbed('Worship', 'Plan services and choose hymns', [
  ['Services', servicesView], ['Hymn library', () => crudView('hymns',
    [{ label: 'Title', key: 'title' }, { label: 'Hymnal #', key: 'hymnal_number' }, { label: 'Tune', key: 'tune' }, { label: 'Themes', key: 'themes' }],
    [{ name: 'title', label: 'Title', required: true }, { name: 'hymnal_number', label: 'Hymnal number (e.g. UMH 378)' }, { name: 'tune', label: 'Tune' },
      { name: 'themes', label: 'Themes (comma separated)' }, { name: 'notes', label: 'Notes' }])],
]);

const ITEM_TYPES = ['prelude', 'call to worship', 'hymn', 'prayer', 'scripture', 'sermon', 'offering', 'creed', 'communion', 'announcement', 'benediction', 'postlude', 'other'];

function servicesView() {
  const root = h('div'), planner = h('div');
  const list = crudView('services', [{ label: 'Date', key: 'date' }, { label: 'Title', key: 'title' }, { label: 'Season', key: 'season' }, { label: 'Scripture', key: 'scripture' }, { label: 'Sermon', key: 'sermon_title' }],
    [{ name: 'date', label: 'Date', type: 'date', required: true, default: today() }, { name: 'title', label: 'Title', required: true },
      { name: 'season', label: 'Liturgical season' }, { name: 'scripture', label: 'Scripture' }, { name: 'sermon_title', label: 'Sermon title' }, { name: 'notes', label: 'Notes' }]);
  const picker = h('select', {}), pickBar = h('div', { class: 'bar' }, h('label', {}, 'Order of service for:'), picker);
  async function refreshPicker() {
    const svc = await api('GET', 'services');
    picker.replaceChildren(h('option', { value: '' }, 'Choose a service…'), svc.map(s => h('option', { value: s.id }, `${s.date} — ${s.title}`)));
  }
  picker.onchange = () => picker.value ? openPlanner(Number(picker.value)) : planner.replaceChildren();
  async function openPlanner(id) {
    const [items, hymns] = await Promise.all([api('GET', `services/${id}/items`), api('GET', 'hymns')]);
    let list = items.map(i => ({ ...i }));
    const msg = h('span', { class: 'muted' });
    const draw = () => planner.replaceChildren(h('table', {}, h('thead', {}, h('tr', {}, ['#', 'Type', 'Title / hymn', 'Leader', 'Notes', ''].map(t => h('th', {}, t)))),
      h('tbody', {}, list.map((it, i) => h('tr', {},
        h('td', {}, i + 1),
        h('td', {}, h('select', { onchange: e => { it.type = e.target.value; draw(); } }, ITEM_TYPES.map(t => h('option', { value: t, selected: t === it.type }, t)))),
        h('td', {}, it.type === 'hymn'
          ? h('select', { onchange: e => { it.hymn_id = Number(e.target.value) || null; } }, h('option', { value: '' }, '—'),
            hymns.map(hy => h('option', { value: hy.id, selected: hy.id === it.hymn_id }, `${hy.hymnal_number ? hy.hymnal_number + ' · ' : ''}${hy.title}`)))
          : h('input', { value: it.title ?? '', oninput: e => { it.title = e.target.value; } })),
        h('td', {}, h('input', { value: it.leader ?? '', oninput: e => { it.leader = e.target.value; } })),
        h('td', {}, h('input', { value: it.notes ?? '', oninput: e => { it.notes = e.target.value; } })),
        h('td', {}, h('button', { class: 'link', onclick: () => { if (i) { [list[i - 1], list[i]] = [list[i], list[i - 1]]; draw(); } } }, '↑'),
          h('button', { class: 'link', onclick: () => { if (i < list.length - 1) { [list[i + 1], list[i]] = [list[i], list[i + 1]]; draw(); } } }, '↓'),
          h('button', { class: 'link', onclick: () => { list.splice(i, 1); draw(); } }, '✕'))))),
    ), h('div', { class: 'bar' },
      h('button', { class: 'btn ghost', onclick: () => { list.push({ type: 'other' }); draw(); } }, '+ Add element'),
      h('button', { class: 'btn', onclick: async () => { list = await api('PUT', `services/${id}/items`, { items: list }); draw(); msg.textContent = 'Saved.'; } }, 'Save order of service'),
      h('button', { class: 'btn ghost', onclick: () => window.print() }, 'Print'), msg));
    draw();
  }
  refreshPicker();
  root.append(list, h('h3', {}, 'Order of service'), pickBar, planner);
  return root;
}

const giving = () => tabbed('Finance', 'Giving, budget and spending', [
  ['Giving', () => crudView('donations',
    [{ label: 'Date', key: 'date' }, { label: 'Donor', get: (r, l) => { const m = l.membersRows.find(x => x.id === r.member_id); return m ? personName(m) : 'Anonymous / cash'; } },
      { label: 'Fund', get: (r, l) => l.fundsRows.find(f => f.id === r.fund_id)?.name }, { label: 'Method', key: 'method' }, { label: 'Amount', key: 'amount', type: 'money' }],
    [{ name: 'date', label: 'Date', type: 'date', required: true, default: today() },
      { name: 'member_id', label: 'Donor', type: 'select', options: l => opts(l.membersRows, personName) },
      { name: 'fund_id', label: 'Fund', type: 'select', required: true, options: l => opts(l.fundsRows, f => f.name) },
      { name: 'amount', label: 'Amount ($)', type: 'money', required: true },
      { name: 'method', label: 'Method', type: 'select', options: ['cash', 'check', 'online', 'ach'].map(x => [x, x]), default: 'check' }, { name: 'note', label: 'Note' }],
    { lookups: { members: 'members', funds: 'funds' } })],
  ['Expenses', () => crudView('expenses',
    [{ label: 'Date', key: 'date' }, { label: 'Payee', key: 'payee' }, { label: 'Category', key: 'category' }, { label: 'Amount', key: 'amount', type: 'money' }],
    [{ name: 'date', label: 'Date', type: 'date', required: true, default: today() }, { name: 'payee', label: 'Payee', required: true },
      { name: 'category', label: 'Category (matches budget)', required: true }, { name: 'amount', label: 'Amount ($)', type: 'money', required: true }, { name: 'note', label: 'Note' }])],
  ['Budget', () => crudView('budget',
    [{ label: 'Year', key: 'year' }, { label: 'Type', key: 'kind' }, { label: 'Category / fund', key: 'category' }, { label: 'Budgeted', key: 'amount', type: 'money' }],
    [{ name: 'year', label: 'Year', type: 'number', required: true, default: thisYear() }, { name: 'kind', label: 'Type', type: 'select', required: true, options: [['income', 'Income (category = fund name)'], ['expense', 'Expense']] },
      { name: 'category', label: 'Category / fund name', required: true }, { name: 'amount', label: 'Amount ($)', type: 'money', required: true }])],
  ['Funds', () => crudView('funds', [{ label: 'Fund', key: 'name' }, { label: 'Restricted', get: r => (r.restricted ? 'Yes' : 'No') }],
    [{ name: 'name', label: 'Name', required: true }, { name: 'restricted', label: 'Restricted giving', type: 'check' }])],
  ['Budget vs actual', financeReport],
  ['Giving statements', statements],
]);

function yearBar(onChange, initial = thisYear()) {
  return h('input', { type: 'number', value: initial, style: 'width:90px', onchange: e => onChange(Number(e.target.value)) });
}

function financeReport() {
  const root = h('div'), out = h('div');
  const load = async y => {
    const r = await api('GET', `reports/finance?year=${y}`);
    out.replaceChildren(
      h('div', { class: 'tiles' }, tile('Total giving', money(r.totalGiving)), tile('Total spending', money(r.totalSpending)), tile('Net', money(r.net))),
      h('table', {}, h('thead', {}, h('tr', {}, ['Type', 'Category', 'Budget', 'Actual', 'Remaining'].map((t, i) => h('th', { class: i > 1 ? 'num' : '' }, t)))),
        h('tbody', {}, r.budget.map(b => h('tr', {}, h('td', {}, b.kind), h('td', {}, b.category), h('td', { class: 'num' }, money(b.budget)), h('td', { class: 'num' }, money(b.actual)),
          h('td', { class: 'num ' + (b.remaining < 0 && b.kind === 'expense' ? 'neg' : '') }, money(b.remaining)))))),
      r.budget.length ? null : h('p', { class: 'muted' }, 'Add budget lines on the Budget tab to compare against actuals.'));
  };
  root.append(h('div', { class: 'bar' }, h('label', {}, 'Year'), yearBar(load)), out); load(thisYear());
  return root;
}

function statements() {
  const root = h('div'), out = h('div'), year = yearBar(() => {});
  const sel = h('select', {});
  api('GET', 'members').then(ms => sel.append(h('option', { value: '' }, 'Choose a member…'), ms.map(m => h('option', { value: m.id }, personName(m)))));
  sel.onchange = async () => {
    if (!sel.value) return out.replaceChildren();
    const s = await api('GET', `members/${sel.value}/statement?year=${year.value}`);
    out.replaceChildren(h('div', { class: 'card' }, h('h3', {}, `${s.member} — ${s.year} giving statement`),
      h('table', {}, h('tbody', {}, s.gifts.map(g => h('tr', {}, h('td', {}, g.date), h('td', {}, g.fund), h('td', { class: 'num' }, money(g.amount)))))),
      h('p', {}, h('b', {}, `Total: ${money(s.total)}`)), h('button', { class: 'btn ghost', onclick: () => window.print() }, 'Print')));
  };
  root.append(h('div', { class: 'bar' }, sel, h('label', {}, 'Year'), year), out);
  return root;
}

const tile = (label, value) => h('div', { class: 'tile' }, h('span', { class: 'muted' }, label), h('b', {}, value));

const payroll = () => tabbed('Payroll', 'Staff and pay-period entries, exportable to your payroll provider', [
  ['Staff', () => crudView('staff', [{ label: 'Name', key: 'name' }, { label: 'Title', key: 'title' }, { label: 'Payroll ID', key: 'external_id' }, { label: 'Pay type', key: 'pay_type' }, { label: 'Rate', key: 'rate', type: 'money' }],
    [{ name: 'name', label: 'Name', required: true }, { name: 'title', label: 'Title' }, { name: 'external_id', label: 'Employee ID in payroll system' },
      { name: 'pay_type', label: 'Pay type', type: 'select', options: [['salary', 'Salary (per period)'], ['hourly', 'Hourly']], default: 'salary' },
      { name: 'rate', label: 'Rate ($)', type: 'money' }, { name: 'active', label: 'Active', type: 'check', default: 1 }])],
  ['Pay periods', () => crudView('payroll', [{ label: 'Staff', get: (r, l) => l.staffRows.find(s => s.id === r.staff_id)?.name }, { label: 'Start', key: 'period_start' }, { label: 'End', key: 'period_end' },
    { label: 'Hours', key: 'hours', type: 'num' }, { label: 'Gross', key: 'gross', type: 'money' }],
    [{ name: 'staff_id', label: 'Staff member', type: 'select', required: true, options: l => opts(l.staffRows, s => s.name) },
      { name: 'period_start', label: 'Period start', type: 'date', required: true }, { name: 'period_end', label: 'Period end', type: 'date', required: true },
      { name: 'hours', label: 'Hours', type: 'number' }, { name: 'gross', label: 'Gross pay ($)', type: 'money' }, { name: 'note', label: 'Note' }],
    { lookups: { staff: 'staff' }, extraActions: () => h('a', { class: 'btn ghost', style: 'text-decoration:none', href: '/api/payroll-export' }, 'Export CSV for payroll provider') })],
]);

const stats = () => tabbed('Statistics', 'Attendance, baptisms and community events', [
  ['Weekly counts', () => crudView('stats',
    [{ label: 'Sunday', key: 'date' }, { label: 'In person', key: 'worship_attendance', type: 'num' }, { label: 'Online', key: 'online_attendance', type: 'num' },
      { label: 'Children', key: 'children', type: 'num' }, { label: 'Sunday school', key: 'sunday_school', type: 'num' }, { label: 'Professions of faith', key: 'professions_of_faith', type: 'num' }],
    [{ name: 'date', label: 'Date', type: 'date', required: true, default: today() }, { name: 'worship_attendance', label: 'Worship attendance (in person)', type: 'number' },
      { name: 'online_attendance', label: 'Online attendance', type: 'number' }, { name: 'children', label: 'Children in worship', type: 'number' },
      { name: 'sunday_school', label: 'Sunday school', type: 'number' }, { name: 'professions_of_faith', label: 'Professions of faith', type: 'number' }, { name: 'notes', label: 'Notes' }])],
  ['Events', () => crudView('events', [{ label: 'Date', key: 'date' }, { label: 'Event', key: 'title' }, { label: 'Kind', key: 'kind' }, { label: 'Attendance', key: 'attendance', type: 'num' }],
    [{ name: 'date', label: 'Date', type: 'date', required: true, default: today() }, { name: 'title', label: 'Title', required: true },
      { name: 'kind', label: 'Kind', type: 'select', options: ['community', 'study', 'camp', 'outreach', 'other'].map(x => [x, x]), default: 'community' },
      { name: 'attendance', label: 'Attendance', type: 'number' }, { name: 'notes', label: 'Notes' }])],
  ['Monthly report', statsReport],
]);

function statsReport() {
  const root = h('div'), out = h('div');
  const load = async y => {
    const r = await api('GET', `reports/stats?year=${y}`);
    const cols = [['Month', 'month'], ['Sundays', 'sundays'], ['Avg worship', 'avgWorship'], ['Avg online', 'avgOnline'], ['Avg children', 'avgChildren'], ['Avg Sun. school', 'avgSundaySchool'],
      ['Baptisms', 'baptisms'], ['Professions', 'professions'], ['Events', 'events']];
    out.replaceChildren(
      h('div', { class: 'tiles' }, ...Object.entries(r.membership).map(([k, v]) => tile(`${k[0].toUpperCase()}${k.slice(1)} members`, v))),
      h('table', {}, h('thead', {}, h('tr', {}, cols.map(([l], i) => h('th', { class: i ? 'num' : '' }, l)))),
        h('tbody', {}, r.months.map(m => h('tr', {}, cols.map(([, k], i) => h('td', { class: i ? 'num' : '' }, m[k] ?? '—')))))),
      h('p', { class: 'muted' }, 'Baptisms are counted from the baptism date on each member record.'));
  };
  root.append(h('div', { class: 'bar' }, h('label', {}, 'Year'), yearBar(load)), out); load(thisYear());
  return root;
}

async function dashboard() {
  const y = thisYear();
  const [f, s] = await Promise.all([api('GET', `reports/finance?year=${y}`), api('GET', `reports/stats?year=${y}`)]);
  const withData = s.months.filter(m => m.avgWorship != null);
  const last = withData.at(-1);
  return h('div', {}, h('h2', {}, `${y} at a glance`),
    h('div', { class: 'tiles' },
      tile('Active members', s.membership.active ?? 0),
      tile('Avg worship (latest month)', last ? last.avgWorship : '—'),
      tile('Baptisms this year', s.months.reduce((a, m) => a + m.baptisms, 0)),
      tile('Events this year', s.months.reduce((a, m) => a + m.events, 0)),
      tile('Giving YTD', money(f.totalGiving)), tile('Spending YTD', money(f.totalSpending))));
}

const SECTIONS = [['Dashboard', dashboard], ['People', members], ['Worship', worship], ['Finance', giving], ['Payroll', payroll], ['Statistics', stats]];

async function shell() {
  const main = h('main'), nav = h('nav', {}, h('h1', {}, '⛪ Church Manager'));
  const go = async i => {
    [...nav.querySelectorAll('button')].forEach((b, j) => b.classList.toggle('on', i === j));
    try { main.replaceChildren(await SECTIONS[i][1]()); } catch (e) { main.replaceChildren(h('p', { class: 'err' }, e.message)); }
  };
  SECTIONS.forEach(([name], i) => nav.append(h('button', { onclick: () => go(i) }, name)));
  nav.append(h('button', { onclick: async () => { await api('POST', 'logout'); boot(); } }, 'Sign out'));
  $app.replaceChildren(h('div', { class: 'shell' }, nav, main));
  go(0);
}

function loginView(needsSetup) {
  const err = h('div', { class: 'err' });
  const email = h('input', { type: 'email', required: true, autocomplete: 'username' }), pw = h('input', { type: 'password', required: true, minlength: needsSetup ? 10 : null, autocomplete: needsSetup ? 'new-password' : 'current-password' });
  $app.replaceChildren(h('form', { class: 'card login', onsubmit: async e => {
    e.preventDefault();
    try { await api('POST', needsSetup ? 'setup' : 'login', { email: email.value, password: pw.value }); shell(); } catch (ex) { err.textContent = ex.message; }
  } }, h('h2', {}, needsSetup ? 'Create the pastor account' : 'Sign in'),
  needsSetup ? h('p', { class: 'muted' }, 'First run: choose an email and a password of at least 10 characters.') : null,
  h('label', {}, 'Email'), email, h('label', {}, 'Password'), pw, err, h('button', { class: 'btn', type: 'submit' }, needsSetup ? 'Create account' : 'Sign in')));
}

async function boot() {
  const s = await api('GET', 'session');
  s.authenticated ? shell() : loginView(s.needsSetup);
}
boot();
