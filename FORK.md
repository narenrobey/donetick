# Fork notes (narenrobey/donetick)

This is a personal self-hosting fork of [donetick/donetick](https://github.com/donetick/donetick).
It tracks upstream **stable release tags** (no betas) and carries a small stack of
fork-only commits on top, so upgrading is "replay our commits onto the next release".

## What the fork changes

| Commit | Change |
| --- | --- |
| Remove outside calls when in selfhost mode | `User.IsPlusMember()` always returns `true` (all plus features unlocked); OIDC avatar URL is no longer fetched over HTTP to validate it. |
| Vendor self-hosted frontend build | Prebuilt `donetick/frontend` (`npm run build-selfhosted`) committed into `frontend/dist`, so `go build` / `docker build` serve the real UI. Source commit is in `frontend/FRONTEND_VERSION`. |
| Don't log GORM record-not-found as errors | `IgnoreRecordNotFoundError: true` in `internal/database/database.go`, so expected empty lookups (e.g. completing a chore with no timer session) don't print a red `record not found` line. Real DB errors and slow queries are still logged. |

Expected side effect: upstream tests that assert non-plus users are rejected
(`internal/calendar` `TestManagementRoutes_RequirePlusMember`,
`TestServeCalendar_NonPlusOwnerIsRejected`) fail in this fork.

Current base: see `git describe --tags --abbrev=0 develop`.

## Upgrading to a new upstream release

One-time setup on a new clone:

```bash
git remote add upstream https://github.com/donetick/donetick.git
```

1. **Find the new stable release** and when it was published:

   ```bash
   git fetch upstream --tags
   gh release list -R donetick/donetick --exclude-pre-releases -L 5
   ```

2. **Back up the current branch** (cheap insurance, removable later):

   ```bash
   OLD=$(git describe --tags --abbrev=0 develop)   # e.g. v0.1.83
   NEW=v0.1.XX                                       # the release you're moving to
   git push origin develop:refs/heads/backup/develop-pre-$NEW
   ```

3. **Replay the fork commits onto the new release:**

   ```bash
   git switch develop
   git rebase --onto $NEW $OLD develop
   ```

   Conflicts, if any, will be in the few files listed above. Keep the fork's
   intent (e.g. `IsPlusMember()` returns `true`). For `frontend/dist`, take
   either side — step 4 replaces it anyway.

4. **Rebuild the frontend that matches the release.** The frontend repo has no
   tags; upstream's release job builds whatever was on its default branch at
   publish time. Pick the last frontend commit before the release's publish time:

   ```bash
   PUBLISHED=$(gh release view $NEW -R donetick/donetick --json publishedAt -q .publishedAt)
   git clone -q https://github.com/donetick/frontend.git /tmp/fe && \
     git -C /tmp/fe rev-list -1 --before="$PUBLISHED" develop && rm -rf /tmp/fe
   scripts/update-frontend.sh <that-commit>        # needs Node 20+
   git add frontend/dist frontend/FRONTEND_VERSION
   git commit -m "Update vendored frontend for $NEW"
   ```

   (Optionally squash this into the existing "Vendor self-hosted frontend
   build" commit with `git rebase -i $NEW` to keep the stack at two commits.)

5. **Verify:**

   ```bash
   docker build -t donetick-fork:test .
   docker run --rm -v "$PWD":/src -w /src golang:1.24-alpine go test ./...
   ```

   Only the plus-member tests listed above should fail. Read the release notes
   for config/env-var renames or migration warnings.

6. **Publish** (history is rewritten by the rebase, so this must be a force-push;
   `--force-with-lease` refuses if GitHub has commits you haven't fetched):

   ```bash
   git push --force-with-lease origin develop
   git push origin $NEW      # so `git describe` works on other clones
   ```

   Other clones of `develop` then need `git fetch && git reset --hard origin/develop`.

Feature branches based on the old `develop` move with:
`git rebase --onto develop <old-develop-sha> <branch>`.

## Deploying to production (Docker)

The repo's `docker-compose.yaml` is upstream's file for their hosted service —
don't use it as-is. The image runs `/donetick`, listens on port `2021`, reads
config from `/config`, and defaults to `DT_ENV=selfhosted`.

1. **Back up the database.** Migrations run automatically at startup and are not
   reversible. SQLite: stop the container and copy the `.db` file. Postgres:
   `pg_dump`.

2. **Keep the current image for rollback:**

   ```bash
   docker tag <current-image> donetick-fork:previous
   ```

3. **Build the new image** from an up-to-date checkout:

   ```bash
   git fetch origin && git reset --hard origin/develop
   docker build -t donetick-fork:latest \
     --build-arg VERSION=$(git describe --tags --abbrev=0)-fork \
     --build-arg COMMIT=$(git rev-parse --short HEAD) .
   ```

4. **Check the environment** before starting it:
   - `DT_JWT_SECRET` (32+ chars) **must be set**, or persist `/config` as a volume.
     Otherwise a fresh random secret is generated each time the container is
     recreated and everyone gets logged out.
   - The SQLite file (`DT_SQLITE_PATH`) must live on a mounted volume.
   - Renamed in v0.1.83: `DT_EMAIL_APPHOST` → `DT_EMAIL_APP_HOST`.
   - `config/selfhosted.yaml` is no longer in the repo; it is generated from
     `config/selfhosted.yaml.example` on first start. See
     `config/selfhosted.env.example` for all env vars.

5. **Swap containers and watch startup:**

   ```bash
   docker logs -f <container>        # migrations may take a while on big DBs
   curl -fsS http://localhost:2021/api/v1/health
   ```

   Then open the UI and log in. A hard refresh may be needed once, since the new
   frontend installs a service worker.

6. **Rollback:** stop the new container, restore the database backup, start
   `donetick-fork:previous`. (Restoring the DB is required — the old version
   doesn't know the new schema/migrations.)
