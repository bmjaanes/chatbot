# Church Manager

Church management software for the pastor of a local United Methodist congregation.
Zero npm dependencies: Node 22.13+ (built-in SQLite) and a plain JavaScript front end.

```
npm start        # http://localhost:3000  (PORT, CONTROL_DB, TENANT_DIR env vars supported)
npm test
```

Any church can **Register a church** on the sign-in page and becomes that church's admin.

## Multi-church design

- **One SQLite file per church** (`data/churches/<id>.db`): congregations are physically isolated, and a church can be
  backed up, exported, or deleted on its own. A query bug cannot leak data between churches.
- **`data/control.db`** holds churches, user accounts, and each user's role per church. One person can belong to
  several churches (e.g. a pastor serving a charge, or a district admin) and switch between them.
- **Roles** (enforced on the server for every request):

| Role | Access |
|---|---|
| Admin | Everything, including managing the team |
| Pastor | Everything except team management and payroll |
| Treasurer | Finance and payroll; can look up members to record gifts but not see private notes, birthdates, addresses |
| Secretary | People, distribution lists, statistics |
| Worship leader | Services and hymns; read-only elsewhere |

- Back up the whole `data/` directory.

## What's in v0.1

| Area | Features |
|---|---|
| People | Members/visitors, status, roles (Lay Leader, Trustee, Choir…), baptism and join dates, CSV export |
| Distribution lists | Groups (Evening Bible Study, Summer Camp…), member picker, one-click email list / `mailto:` BCC |
| Worship | Service calendar, drag-free order-of-service builder, hymn library, print view |
| Finance | Funds (restricted/unrestricted), donations, expenses, budget vs. actual, per-member year-end giving statements |
| Payroll | Staff, pay-period entries, CSV export for payroll providers |
| Statistics | Weekly attendance (in person/online/children/Sunday school), events, baptisms, monthly + yearly report |

## Design notes

- Money is stored as integer cents; the API speaks dollars.
- scrypt-hashed passwords, HttpOnly session cookie, CSRF header on writes, 5-failure login lockout.
- Everything is plain REST under `/api/*`, so other denominational systems can later integrate cleanly.

## Honest limits / next steps

1. **Hymnal data.** The hymn library ships with ten public-domain hymns and *no* hymnal numbers.
   The United Methodist Hymnal and *The Faith We Sing* are copyrighted (Discipleship Resources / UMPH);
   enter your own numbers, or ask UMPH about licensed data. Projecting lyrics needs CCLI/OneLicense tracking.
2. **Payroll.** The export is a generic CSV. ADP, Paychex, and Paycor each require partner/API
   approval and a specific import layout; the next step is mapping this CSV to the template your
   provider uses (ADP Run and Paychex Flex both accept CSV time/earnings imports). Not tax-calculating, not a payroll system.
3. **Security/privacy.** Giving and pastoral-care data is sensitive. Before hosting for real churches: HTTPS (and the `Secure` cookie flag),
   encrypted backups, email-based invites and password reset (today an admin sets a temporary password), 2FA, an audit log, and a security review.
4. **Denominational reporting.** The statistics map to the data collected in the annual Local Church Statistics
   (Table I-III) reporting, but field names should be checked against the current GCFA form before relying on it.
   This is the natural place to fix the "silo" problem: add an export/API that your conference or agency can consume.
5. **Conference/denominational layer:** a read-only aggregate view for district and conference staff (consent-based, statistics only,
   never individual giving or member records). This is the part that addresses the data-silo problem across churches.
6. **Planned:** recurring giving imports (Tithe.ly, Givelify, bank CSV), calendar/room booking,
   email sending (SMTP), childcare check-in, moving the control database to Postgres once hosted at scale.
