# Church Manager

Church management software for the pastor of a local United Methodist congregation.
Zero npm dependencies: Node 22.13+ (built-in SQLite) and a plain JavaScript front end.

```
npm start        # http://localhost:3000  (PORT, DB_PATH env vars supported)
npm test
```

First visit asks you to create the pastor account. Data lives in `data/church.db` (git-ignored). Back this file up.

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
- Single-pastor login (scrypt hashed passwords, HttpOnly session cookie, CSRF header on writes).
- Everything is plain REST under `/api/*`, so other denominational systems can later integrate cleanly.

## Honest limits / next steps

1. **Hymnal data.** The hymn library ships with ten public-domain hymns and *no* hymnal numbers.
   The United Methodist Hymnal and *The Faith We Sing* are copyrighted (Discipleship Resources / UMPH);
   enter your own numbers, or ask UMPH about licensed data. Projecting lyrics needs CCLI/OneLicense tracking.
2. **Payroll.** The export is a generic CSV. ADP, Paychex, and Paycor each require partner/API
   approval and a specific import layout; the next step is mapping this CSV to the template your
   provider uses (ADP Run and Paychex Flex both accept CSV time/earnings imports). Not tax-calculating, not a payroll system.
3. **Security/privacy.** Giving and pastoral-care data is sensitive. Before real use: HTTPS in front of the app,
   encrypted backups, and (for multi-user) per-role permissions so e.g. a treasurer can't see pastoral notes.
4. **Denominational reporting.** The statistics map to the data collected in the annual Local Church Statistics
   (Table I-III) reporting, but field names should be checked against the current GCFA form before relying on it.
   This is the natural place to fix the "silo" problem: add an export/API that your conference or agency can consume.
5. **Planned:** multi-user roles, recurring giving imports (Tithe.ly, Givelify, bank CSV), calendar/room booking,
   email sending (SMTP), childcare check-in, Postgres + hosting for multi-church use.
