# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Donetick is an open-source task/chore management app. This repo (`donetick/donetick`) is the Go backend ("core"). The frontend lives in a separate repo (`donetick/frontend`) and is embedded into this binary as static assets under `frontend/dist` Upstream only checks in a placeholder `index.html` and builds the real UI in its release workflow. **This fork vendors a prebuilt self-hosted frontend into `frontend/dist`** (source commit recorded in `frontend/FRONTEND_VERSION`) so plain `go build`/`docker build` serve the real UI. Regenerate with `scripts/update-frontend.sh <frontend-ref>` (frontend repo has no tags — use the commit on its default branch when the matching backend release was published). On merge conflicts in `frontend/dist`, keep ours.

This working copy (`origin` = `narenrobey/donetick`) is a **personal fork** with self-hosting customizations (e.g. `IsPlusMember()` hardcoded true, see Auth section below) layered on top of upstream `donetick/donetick`. `develop` is upstream's latest **stable release tag** plus a small stack of fork-only commits, rebased (not merged) onto each new release. **See `FORK.md`** for the fork's changes, the step-by-step upgrade procedure, and production deployment notes; keep it updated when fork commits change.

## Upstream compatibility (important)

**Goal: this fork must always be cleanly mergeable/rebaseable against upstream `donetick/donetick`.** Every change should be made with that in mind:

- Prefer minimal, additive, clearly-isolated diffs over edits that touch a lot of an existing shared file. The smaller and more localized a fork-specific change, the less likely it collides with upstream's own edits to that file.
- Never reformat, reorder, or rename existing code as a side effect of an unrelated change (this includes "drive-by" cleanups) — it inflates the diff on files upstream is actively developing and turns trivial merges into manual conflict resolution.
- Don't refactor or restructure a shared module (handler.go, config.go, main.go, model files, etc.) unless the task specifically requires it. These are exactly the files upstream touches most, so unnecessary structural changes there are the highest-risk source of future conflicts.
- Where possible, express fork-specific behavior as something additive and config/env-var-gated (a new field, a new branch, a new file) rather than rewriting upstream's existing logic in place — this way upstream's version of that code can keep evolving underneath with less friction.
- Deliberate, permanent fork divergences from upstream behavior (like `IsPlusMember()` always returning `true`) should be marked with a short comment in the code and noted in this file, so they're easy to recognize and deliberately re-apply (rather than silently lost or silently kept) when resolving a merge/rebase conflict.
- **Before making a change that would create a broad or invasive diff in a shared file, or that upstream is likely also actively modifying, say so and explain the conflict risk before proceeding** — don't just make the change silently.

## Common commands

```bash
# Run the app locally (reads config/local.yaml by default)
go run .

# Run with a specific config environment (config/<env>.yaml)
DT_ENV=selfhosted go run .          # config/selfhosted.yaml
DT_ENV=prod go run .                # config/prod.yaml

# Build
go build -o donetick .

# Run all tests
go test ./...

# Run a single package's tests
go test ./internal/chore/...

# Run a single test
go test ./internal/chore/ -run TestFunctionName -v

# Lint (pinned version used in CI)
go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.64.8
go install github.com/quasilyte/go-ruleguard/cmd/ruleguard@v0.4.5
golangci-lint run
golangci-lint run --fix   # apply safe fixes

# Check that time.Now() is always followed by .UTC() (CI enforces this; excludes _test.go by default)
bash scripts/check-time-utc.sh
bash scripts/check-time-utc.sh --staged   # only staged files
```

CI (`.github/workflows/go-build.yml`) runs, on every PR/push to `main`: the UTC-time check, `go mod tidy && git diff --exit-code`, `golangci-lint run`, `go test ./...`, and a build that generates swagger docs (`swag init -g docs/handler.go`) before `go build`.

## Configuration

Config is loaded via Viper in `config/config.go` (`LoadConfig`). The `DT_ENV` env var selects which YAML file to load from `config/`:
- `local` (default) → `config/local.yaml`
- `selfhosted` → `config/selfhosted.yaml`
- `prod` → `config/prod.yaml`
- `r2` → `config/r2.yaml`

Any config field can be overridden by an env var with the `DT_` prefix (Viper `AutomaticEnv` + `SetEnvPrefix("DT")`), e.g. `DT_DATABASE_TYPE`, `DT_SQLITE_PATH`, `DT_JWT_SECRET`. The JWT secret must be 32+ characters. `config/selfhosted.yaml` is a good reference for the full set of config keys (database, jwt, server, oauth2, email, storage, realtime, scheduler_jobs, single-circle-instance mode, etc).

## Architecture

### Dependency injection via `fx`

`main.go` wires the entire app with [uber-go/fx](https://github.com/uber-go/fx). Every repository, service, and handler is an `fx.Provide`d constructor, and route registration functions (`chore.Routes`, `chore.APIs`, `user.Routes`, `frontend.Routes`, etc.) are `fx.Invoke`d at the end. When adding a new feature module, add its constructors to the `fx.Provide` list and its route-registration function to the `fx.Invoke` list in `main.go`.

DB migrations, the notification scheduler, event producer, MFA/auth cleanup jobs, draft-cleanup, and the realtime service are all started from `OnStart` lifecycle hooks in `newServer` (main.go) — not from `main()` directly.

### Module layout (`internal/<feature>/`)

Most features follow this shape:
- `model/` — GORM models for the feature.
- `repo/` — a `<Feature>Repository` struct wrapping `*gorm.DB`, holding all queries for the feature.
- `handler.go` — `Handler` struct + gin handler methods, used by the **internal/frontend API** (routes registered under `api/v1/...`, cookie/JWT auth via `MultiAuthMiddleware`). Has its own `Routes(router, h, multiAuthMiddleware)` func.
- `api.go` (only some features: `chore`, `thing`) — a separate `API` struct + handler methods for the **external API ("eAPI")**, routes registered under `eapi/v1/...`, authenticated via long-lived API tokens (`APITokenMiddleware`), some endpoints gated behind `RequirePlusMemberMiddleware`. Has its own `APIs(cfg, api, r, auth, limiter, userRepo)` func. This is the public REST API recommended for external integrations (README calls this "eAPI").

Do not mix these two: internal `Handler` methods are for the web/mobile app and use session/JWT cookies; `API` methods are for external automation/API-token clients and must stay backward compatible.

### Custom migration framework

Two migration mechanisms exist and both run at startup when `database.migration: true`:
1. `database.Migration(db)` (`internal/database/migration.go`) — GORM `AutoMigrate` over the full model list (schema-level: adding tables/columns).
2. `migrations.Run(ctx, db)` (`migrations/`) — a custom one-off data-migration framework. Each file in `migrations/` implements `migrations.MigrationScript` (`ID()`, `Description()`, `Up()`, `Down()`) and self-registers via `migrations.Register(...)` in an `init()`. They run in ID order and are tracked in a `Migration` table so each runs once. ID convention is a date prefix, e.g. `20260719_drop_api_token_name_unique.go`. Use this for backfills/data migrations, not schema changes (those belong in the `AutoMigrate` model list).

Startup also runs `database.MigrationScripts(db, cfg)` for anything config-dependent. Because backfill migrations can be slow on large datasets, `fx.StartTimeout` is set to 15 minutes in `main.go` — don't shrink it without checking why.

### Time handling

All timestamps must be UTC. Always write `time.Now().UTC()`, never bare `time.Now()` (exceptions: `.Unix()`/`.UnixMilli()`/etc., and test files). This is enforced by `scripts/check-time-utc.sh` in CI; suppress a specific false-positive line with `// utc-lint:ignore`.

### Handler conventions

- Use `ShouldBindJSON`, not `ShouldBind`, in any file named `handler.go` — enforced by a custom ruleguard rule in `rules.go` (`noShouldBind`), run via golangci-lint's `gocritic`/`ruleguard` linter.
- `internal/error` defines shared error helpers used across handlers for consistent API error responses.

### Realtime sync

`internal/realtime` implements WebSocket + SSE-based live sync (connection pool, ticket-based auth for reconnects, broadcaster, rate limiter). It's wired up with its own `NewAuthMiddleware`, `TicketStore` (has a background cleanup goroutine stopped explicitly in `OnStop`), and `NewPollingHandler` for clients that fall back to polling. Gated by `realtime.enabled`/`realtime.sse_enabled` config.

### Notifications

`internal/notifier` is the core dispatch/scheduling logic (`notifier.Scheduler`, `NotificationPlanner`), fanning out to per-provider implementations in `internal/notifier/service/{telegram,discord,pushover,fcm}`. `scheduler_jobs` config (`due_job`, `overdue_job`, `pre_due_job`) controls polling intervals for due/overdue reminders.

### Storage

`internal/storage` abstracts file attachments behind a `Storage` interface, with `storage.NewStorage` factory-selecting a local-disk or S3-compatible (AWS S3/R2/MinIO) implementation based on `config.Storage.StorageType` (empty = S3-compatible, `"local"` = local disk). `URLSigner` similarly has local/S3 implementations for generating signed attachment URLs. A `DraftCleanupService` periodically removes orphaned/unreferenced uploaded files.

### Auth

`internal/auth` provides: JWT session auth (`NewAuthMiddleware`, backed by `appleheart/gin-jwt`-style `jwt.GinJWTMiddleware`), API-token auth (`APITokenMiddleware`) for the eAPI, `MultiAuthMiddleware` (accepts either), OIDC/OAuth2 login (`identity_provider.go`) with optional group-based role sync (`role_resolver.go` — admin/manager/member roles resolved from `DT_OAUTH2_ADMIN_GROUPS`/`DT_OAUTH2_MANAGER_GROUPS` on every login), MFA (delegates to `internal/mfa`), and `ImpersonationMiddleware` (admin-as-user support via `X-Impersonate-User-ID`).

`DT_SINGLE_CIRCLE_INSTANCE=true` mode is for self-hosted single-household deployments: hides circle management UI, disables join/leave/delete-member endpoints, and funnels new OIDC users into a shared circle (ID 1) instead of creating personal circles. See README for the full env var table.

Note: in this tree, `User.IsPlusMember()` (`internal/user/model/model.go`) is hardcoded to `return true` ("self-hosted: no subscription system"), so `RequirePlusMemberMiddleware` and all other plus-gated checks (storage quota, realtime access, circle member limits, etc.) never actually block anything here — the subscription/Stripe/RevenueCat plumbing in `external/payment` exists but isn't wired to gate features in self-hosted mode. Because of this, upstream tests asserting non-plus users are rejected (e.g. `internal/calendar` `TestManagementRoutes_RequirePlusMember`, `TestServeCalendar_NonPlusOwnerIsRejected`) fail in this fork — expected.

### Swagger docs

API docs are generated with `swag init -g docs/handler.go` (see `docs/`) and served when `server.serve_swagger: true`. Regenerate docs after changing handler signatures/comments if the change affects the documented API surface.
