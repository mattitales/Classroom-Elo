# Classroom Elo — Deployable v0.1

A browser-based classroom game arcade. Students play **real games on physical boards** and report matches using the shared classroom station. Elo ratings update **immediately**. The manager can correct, hold, delete, or restore matches and have the historical ratings **replayed from valid results**.

## What's included

- Public arcade homepage, recent games and class/overall rankings for each custom game
- Station unlock code: register players and report matches only from a classroom device that knows the code
- Student registration pending manager approval; real names visible only in the authenticated manager dashboard
- Custom games and classes; players can only report matches against classmates
- K=32 Elo calculations in PostgreSQL, not in browser code
- Duplicate warning for same pair/game within 90 seconds; 8-per-hour limit for same pair/game
- Authenticated manager dashboard: approve/reject/edit players; add/disable games; add classes; search/filter match history; edit/hold/delete/restore matches individually or in bulk
- Season rollover: archive old, start fresh/carry Elo/soft-reset; previous season records are retained in the database
- Secure manager-only JSON data export (contains student names; handle privately)
- Responsive interface, GitHub Pages compatible

**Not yet included:** achievement/XP/Rupee rewards, match search filters and bulk deletion, full historical season browsing/restore in the UI, player Elo graphs, prize management, server-side abuse throttling by IP, a cryptographically authenticated student identity, and automated school-year roster rollover. These are future milestones, *not* completed features.

## Why Supabase rather than only GitHub Pages?

A static GitHub Pages app alone can't share live ratings or securely compute match updates. Supabase provides a Postgres database, transaction-safe RPC functions, and manager authentication. The data operations are carried out in SQL, which stops students from editing ratings directly from the browser. The public `anon` key is safe to put in browser code; the `service_role` key is **not**.

## Setup (about 6 steps)

1. Create a project at **https://supabase.com/dashboard**. Keep your database password private.
2. Open **SQL Editor**, paste/run `sql/001_schema.sql` once. It creates tables, RPC endpoints, access restrictions, sample class periods/games, and Season 1.
3. In **Authentication → Users**, create your own email/password manager user. Copy its **UID**. If using a real school account, follow district policy.
4. In SQL Editor run **only this statement**, replacing the UUID with your actual Auth user UID:
   ```sql
   insert into public.admin_users (user_id)
   values ('REPLACE-WITH-YOUR-AUTH-USER-UUID');
   ```
5. From **Project Settings → API**, copy **Project URL** and **publishable key (or legacy anon key)** into `config.js`. **NEVER** paste the service-role key or database password into files deployed to GitHub.
6. Upload `index.html`, `config.js`, and the `assets` folder to a **GitHub repository**. Enable **Settings → Pages → Deploy from a branch → main / root**. Open your new GitHub Pages URL.

Sign in on **Manager** and immediately change the initial station code (`CHANGE-ME-2026`) in **Settings**. On the classroom computer open **Report Match** or **Join** and enter that code once. It is remembered only for that browser tab/session. Students on other devices can view public leaderboards without the code.

### Security and school use

- **Before allowing real student data:** obtain school/district authorization and check FERPA, vendor agreements, consent, retention and student privacy requirements. Test using fictional accounts first.
- Real student names are kept in manager-only RPC output. Only approved nicknames go into public standings. Avoid publishing nicknames that identify students unless school policy permits it.
- The station code is **not individual student authentication**. Anyone who learns it could submit matches. It reduces drive-by submissions but does not prevent deliberate misuse. Rotate it if shared; moderate matches; consider device-bound authorization for a later iteration.
- Users who have access to the class station can submit match claims for any two approved classmates. Teacher edits/deletes can reverse them. The app is not tamper-proof against repeated attempts.
- The website requires internet access for database operations. It is not yet an offline PWA.
- SQL `security definer` functions have empty `search_path`, explicit privileges, and admin UID checks; don't add new public RPCs without similar review.
- The manager account controls private student data; use a strong password and consider MFA. Do not hand its login to students.

### How the data works

`matches` is the authoritative ledger; a match has `active`, `held`, or `deleted` status. SQL `private.rebuild(season)` **replays active matches in chronological order**, updating `ratings` and each active match's before/after ratings. This runs in one transaction after each match entry or edit and uses an advisory lock to serialize writes. Changing a match retroactively changes subsequent Elo calculations. Future achievements should be projections from the same ledger, not irreversible side effects.

`seasons` are archived by `new_season` but never deleted; rollover baselines for carry/soft reset live in `season_baselines`. Historical match records survive rollover.

### Quality checks before students use it

- Register a fictional student → confirm it doesn't show in rankings → approve as manager → it appears.
- Approve two fictional students in the **same** class, report Chess win → verify Elo changes immediately.
- Attempt a match between different class periods → must be blocked.
- Submit duplicate match within 90 seconds → must be blocked.
- Hold an active match → Elo returns to what it was without that match; restore it → returns.
- Submit multiple sequential matches, delete the earliest → later Elo values recalculate rather than simply subtracting the original points.
- Sign out, open the manager page → no access to student real names or edits.
- Open the public site on another device → same rankings.

## Recommended next iterations

1. Test/setup the deployed core with fictional students and an active manager account.
2. Add match search/filter and bulk moderation, plus public player profiles / historical Elo graph.
3. Expand archive browsing and per-game/semester controls.
4. Later: achievements, XP, manager-awarded bonuses and physical Zelda Rupee tracking, derived from valid match events.

## Project layout

```
index.html                Static entry point
config.js                 Public Supabase URL + publishable key (never secrets)
assets/styles.css         Arcade look and responsive layouts
assets/app.js             Student + manager screens, using RPC APIs
assets/favicon.svg        App icon
sql/001_schema.sql        Database, permissions, calculations, endpoints
```

This code is a functional **implementation draft**, not a tested production deployment: it still requires your Supabase project, credentials, district approval, and live end-to-end testing. No real database has been connected in this environment.
