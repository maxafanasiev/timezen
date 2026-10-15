# Release & CI/CD (Timezen)

Pipeline: **GitHub Actions + Fastlane**. Signing certs/profiles are managed by **fastlane match**.

| Workflow | Trigger | What it does |
|---|---|---|
| `pr.yml` (PR build) | every pull request | unsigned simulator build, no secrets |
| `ios.yml` (iOS CI) | push/merge to `develop` (code changes only), manual | signed build → TestFlight, then the groups from `TESTFLIGHT_GROUPS` |
| `release.yml` (App Store release) | push/merge to `main` (code changes only), manual | submits the latest TestFlight build of the current `MARKETING_VERSION` to App Store review with `fastlane/whats_new.txt`, auto-release after approval; skips if that version is already submitted or live |

Work goes into `develop` (the default branch); `main` only receives release merges from `develop`.
Repo rulesets enforce it: both branches accept changes only through PRs (no direct or force
pushes, no deletion), and PRs into `main` must pass `source-is-develop` (`main-source.yml`).

- Bundle id: `com.afanasievmaksym.timezen`
- Apple Team ID: `2ZAN8NR82A`
- Repo: https://github.com/maxafanasiev/timezen

## One-time setup

### 1. App Store Connect
1. Create the app record: App Store Connect → **Apps → +** → name **Timezen**, bundle id
   `com.afanasievmaksym.timezen`, SKU `timezen`.
2. Create an **API key**: Users and Access → **Integrations → App Store Connect API → +**
   (role: App Manager). Download the `AuthKey_XXXXXX.p8` (once!). Note the **Key ID** and **Issuer ID**.

### 2. fastlane match (signing)
`match` stores the distribution certificate + provisioning profile, encrypted, in a **separate
private git repo**.
```sh
bundle install
# create an empty PRIVATE repo, e.g. github.com/maxafanasiev/timezen-certs, then:
bundle exec fastlane match appstore \
  --git_url https://github.com/maxafanasiev/timezen-certs \
  --app_identifier com.afanasievmaksym.timezen
```
It will ask for a passphrase — remember it (that's `MATCH_PASSWORD`).

### 3. GitHub Secrets
Repo → Settings → Secrets and variables → **Actions** → New repository secret:

| Secret | Value |
|--------|-------|
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | API Issuer ID |
| `ASC_KEY_CONTENT` | base64 of the `.p8`: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `MATCH_PASSWORD` | the match passphrase |
| `MATCH_GIT_URL` | `https://github.com/maxafanasiev/timezen-certs` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 of `USERNAME:GITHUB_PAT` (PAT with repo scope) |

Repository **variable** (Variables tab): `TESTFLIGHT_GROUPS`, comma-separated TestFlight group
names, currently `Internal Testing,all`. Each build is sent to those groups (external ones go through
Beta App Review); when empty, builds are only uploaded.

## Releasing

1. Merge feature PRs into `develop` → each merge is a new TestFlight build (number = latest + 1).
   The merge commit message is the "What to Test" text.
2. Before a release, bump `MARKETING_VERSION` (project + `project.yml`) and update
   `fastlane/whats_new.txt` in `develop`, and let that build reach TestFlight.
3. Open a PR `develop` → `main` and merge it → the build is submitted for App Store review.

Without a version bump the release workflow just logs that the version is already out and exits.

## Local (from a Mac)

```sh
bundle install
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_CONTENT=$(base64 -i AuthKey.p8)
bundle exec fastlane beta
```

## Notes
- Build number auto-increments to `latest TestFlight build + 1`.
- The app is signed for distribution via the `match AppStore com.afanasievmaksym.timezen` profile.
- Marketing version lives in the project (`MARKETING_VERSION`); bump it for a new App Store version.
