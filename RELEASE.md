# Release & CI/CD (Timezen)

Pipeline: **GitHub Actions + Fastlane**. Pushing a `v*` tag builds a signed Release `.ipa` and
uploads it to **TestFlight**. Signing certs/profiles are managed by **fastlane match**.

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

## Releasing

```sh
git tag v1.0.0
git push origin v1.0.0        # → GitHub Actions builds & uploads to TestFlight
```
Or run the **iOS CI** workflow manually (Actions tab → Run workflow).

- Internal testers get the build automatically (no review).
- For external testers / App Store: fill metadata + screenshots, then `fastlane release`
  (set `submit_for_review: true` in the Fastfile when ready).

## Local (from a Mac)

```sh
bundle install
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_CONTENT=$(base64 -i AuthKey.p8)
bundle exec fastlane beta
```

## Notes
- Build number auto-increments to `latest TestFlight build + 1`.
- The app is signed for distribution via the `match AppStore com.afanasievmaksym.timezen` profile.
- Marketing version lives in the project (`MARKETING_VERSION`, currently 1.0) — bump it for a new
  App Store version.
