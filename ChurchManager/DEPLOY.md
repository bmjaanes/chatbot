# Putting Church Manager online (so it works on an iPad)

The app is a normal web app. It just needs to run on a server with a public HTTPS address.
Expect roughly **$5/month**: neither Railway nor Fly.io has a lasting free plan for new accounts
(Railway: one-time $5 trial credit, then Hobby at $5/month; Fly.io: short trial, then pay-as-you-go).
Check railway.com/pricing or fly.io/pricing before signing up. Free hosts that wipe their disk (e.g. Render's free tier)
are **not** suitable: every church's data would be lost on restart.

## Option A: Railway (simplest)

1. Create an account at railway.com and connect your GitHub.
2. **New Project → Deploy from GitHub repo** → pick this repository and the `claude/next-time-ios-app` branch (or merge it to `main` first).
3. Open the service → **Settings → Root Directory** → set to `ChurchManager`. Railway will build the included `Dockerfile`.
4. **Add a Volume** to the service, mount path `/data`. *Do not skip this: it is where all church data lives.*
5. **Settings → Networking → Generate Domain.** You get an `https://…up.railway.app` address.
6. Open that address on the iPad in Safari, tap **Register a church**, then **Share → Add to Home Screen**.

## Option B: Fly.io

```
cd ChurchManager
fly launch --no-deploy        # accept the Dockerfile; pick a region near you
fly volumes create data --size 1
```
In the generated `fly.toml` add:
```
[mounts]
  source = "data"
  destination = "/data"
```
then `fly deploy`. Keep it to **one machine**: SQLite files cannot be shared by several servers.

## Before real churches use it

- **Back up the `/data` volume** (Railway/Fly volume snapshots, or a nightly copy elsewhere). It holds every church's database.
- Use a custom domain you control (e.g. `app.yourorg.org`) so you can move hosts later without changing the address.
- Run a security review and get agency/IT sign-off: it will hold donor and pastoral information.
- This design is one server and one volume. It's fine for a pilot with a handful of churches; hundreds of churches means moving to Postgres.

## Environment variables (all optional)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | 3000 | Port to listen on (Railway/Fly set this for you) |
| `DATA_DIR` | `data` (`/data` in Docker) | Where databases are stored |
| `COOKIE_SECURE` | off | Set to `1` to force the HTTPS-only cookie flag. It's added automatically behind an HTTPS proxy. |

A health check is available at `/healthz`.
