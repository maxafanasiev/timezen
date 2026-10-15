# Release & CI/CD (Timezen)

Pipeline: **GitHub Actions + Fastlane**. Signing certs/profiles are managed by **fastlane match**.

| Workflow | Trigger | What it does |
|---|---|---|
| `pr.yml` (PR build) | every pull request | unsigned simulator build, no secrets |
| `ios.yml` (iOS CI) | merge/push to `main` (code changes only), `v*` tag, manual | signed build → TestFlight, then external groups from `TESTFLIGHT_GROUPS` |
| `release.yml` (App Store release) | manual, with a "What's New" text | submits the latest TestFlight build of the current `MARKETING_VERSION` to App Store review, auto-release after approval |

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

Optional repository **variable** (Variables tab): `TESTFLIGHT_GROUPS`, comma-separated external
TestFlight group names. When set, each build is sent to those groups (Beta App Review applies);
when empty, builds are only uploaded.

## Releasing

1. Merge to `main` → a new TestFlight build (number = latest + 1). The merge commit message is
   the "What to Test" text.
2. For a new App Store version, bump `MARKETING_VERSION` in the project first (App Store Connect
   rejects a version that is already released).
3. Actions → **App Store release** → Run workflow, enter the "What's New" text.

Internal testers get every build automatically (no review).

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
