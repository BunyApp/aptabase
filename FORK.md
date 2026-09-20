# Fork notes

`BunyApp/aptabase` is a fork of [`aptabase/aptabase`](https://github.com/aptabase/aptabase).

It is maintained as a **patch series**: the `changes` branch is upstream's `main`
plus a small number of commits, replayed on top on every sync. So this is always
the complete answer to "what have I changed?":

```sh
git log --oneline upstream/main..changes
git diff upstream/main..changes --stat
```

If that command ever starts listing upstream commits, the fork has drifted off
the rebase model and should be put back on it.

## Remotes

| Remote | Repository |
|---|---|
| `origin` | `BunyApp/aptabase` — this fork |
| `upstream` | `aptabase/aptabase` — where syncs come from |

If `upstream` is missing:

```sh
git remote add upstream https://github.com/aptabase/aptabase.git
```

## The patches

### `fork: use Swift vendor id as user id`

Stores the vendor id the SDK sends, instead of the rotating hash upstream
derives in `DailyUserHasher`, so a device stays identifiable across days.

- `src/Features/Ingestion/EventBody.cs` — `UserId`, marked `[Required]`
- `src/Features/Ingestion/Buffer/TrackingEvent.cs` — `UserId` field
- `src/Features/Ingestion/EventsController.cs` — populates it from the request
- `src/Features/Ingestion/Buffer/EventRow.cs` — reads `e.UserId` and ignores the
  hashed `userId` constructor argument that `EventBackgroundWritter` still passes

**This is a deliberate departure from upstream's privacy model.** Upstream makes
users non-identifiable across days by construction; this fork makes them
persistently trackable per device. Keep that in mind for anything
privacy-policy- or GDPR-shaped.

No schema change is involved — the `user_id` column already exists; only what
gets written into it differs.

Note that upstream's error reporting feature has no `user_id` column at all, so
this does not extend to error reports.

### `fork: make vite dev proxy target configurable`

`src/vite.config.ts` reads the dev proxy backend from `APTABASE_API_TARGET`,
defaulting to upstream's `https://localhost:5251`. Behaviour is identical to
upstream when the variable is unset, which keeps the local API port out of git.

Generic enough to offer upstream as a PR; if they take it, this patch disappears.

### `fork: document fork customizations and sync workflow`

This file and `scripts/fork-sync.sh`. Upstream will never touch these paths, so
they never conflict.

## Local development

The fork runs the API over plain HTTP on `:8000` rather than HTTPS on `:5251`.
Both settings live in files git does not track, so they cost nothing at sync time.

**Backend port** — `src/Properties/launchSettings.json` (already ignored via
`.gitignore:11`, seeded from `launchSettings.example.json`):

```json
"applicationUrl": "http://0.0.0.0:8000"
```

**Frontend proxy** — export before `npm run dev`:

```sh
export APTABASE_API_TARGET=http://localhost:8000
```

Neither affects the Docker image: the Dockerfile never reads
`appsettings.Development.json`, and `vite.config.ts`'s proxy applies only to the
dev server.

## Frontend dependencies

Use **npm**, not bun. The image builds the frontend with `npm install` against
`src/package-lock.json` (`Dockerfile:22-23`).

A `src/bun.lock` and two extra `package.json` pins
(`baseline-browser-mapping`, `caniuse-lite`) were dropped from the fork: the
lockfile was never read by any build, and the pins were not root entries in
`package-lock.json`, which made the image's frontend dependencies
non-reproducible and would have broken outright if upstream ever moved to
`npm ci`. They remain in history at commit `2d28f50` if ever needed.

## Syncing with upstream

Either locally, or from GitHub Actions.

### From GitHub Actions

The **Sync fork with upstream** workflow (`.github/workflows/fork-sync.yml`)
does the whole thing: rebases the patch series onto `upstream/main`, builds both
backend and frontend to prove the result still works, and reports the fork
surface in the run summary.

Run it from the Actions tab. **Pushing is opt-in** — leave the `push` input off
for a dry run, which is the safe way to find out whether an upstream sync would
conflict before committing to it. It never pushes on its own, because this
branch is what the production host deploys from.

It also runs as a dry run every Monday at 06:00 UTC, so upstream drift surfaces
on its own. On a conflict it aborts cleanly, leaves the branch untouched, and
opens an issue naming the conflicting paths; resolve those locally with the
script below.

Before force-pushing it tags the previous tip as `fork-sync-backup-<timestamp>`
and pushes that tag, since a force-push leaves the old commits unreachable on
the remote with no reflog to recover them from.

Note that the frontend check runs `npm ci`, which is deliberately stricter than
the Dockerfile's `npm install`: it fails if `package.json` and
`package-lock.json` drift apart.

### Locally

```sh
./scripts/fork-sync.sh
```

It refuses to run on a dirty tree, fetches `upstream`, tags a restore point,
rebases `changes`, and prints the resulting patch series. Re-running when
already current is a no-op.

Then verify and publish:

```sh
dotnet build src/Aptabase.csproj
git push --force-with-lease origin changes
```

The force-push is expected — rebasing gives the fork commits new ids every time.
`--force-with-lease` is the safe form: it refuses if `origin/changes` moved in a
way you have not seen.

`git config rerere.enabled true` is set in this clone, so a conflict resolved
once is replayed automatically on later syncs. It is per-clone config, not
committed — set it again on any fresh clone.

Conflicts, when they occur, are confined to the four Ingestion files and
`src/vite.config.ts`.

## Deploying

The host at `/srv/docker/AptabaseCustomGit/aptabase` clones this fork and builds
the image locally:

```sh
cd /srv/docker/AptabaseCustomGit/aptabase
git fetch origin
git reset --hard origin/changes
docker build -t aptabase-custom:latest .
docker compose -f docker-analytics.yaml up -d
```

**Use `reset --hard`, not `git pull`.** Rebasing gives the commits new ids, so a
pull tries to merge the old local commits against the new ones and either
conflicts or produces a junk merge commit. That clone carries no local commits,
so adopting the new tip outright is the correct operation.
