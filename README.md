# Timezen

**Timezen** is a native SwiftUI iPhone/iPad time tracker — a client for **self-hosted
[SolidTime](https://solidtime.io)** servers. It mirrors the SolidTime desktop app: a compact
start/stop timer with project, task, tags and billable selection, plus your time-entry history
and a personal dashboard.

> Timezen is an independent, unofficial client. "SolidTime" is a trademark of its respective
> owners; this app is not affiliated with or endorsed by SolidTime.

## Features

- **Connect to any self-hosted SolidTime server** with a URL + personal API token (Keychain-stored).
- **Timer + history on one screen** (Clockify-style): running timer pinned on top, day-grouped
  history below with per-day totals.
- **Edit entries** — description, project/task, tags, billable, and start/end/duration.
- **Resume** or **Duplicate** an entry (swipe), **Delete** (swipe).
- **Dashboard** — Day / Week / Month / Half-month / Custom ranges with Current/Previous, totals,
  a per-project stacked bar chart, and a project filter.
- **Dark / Light / System** theme.
- **Multi-organization** support.

## Requirements

- **Xcode 16+** (iOS 17.0+ deployment target).
- A running **SolidTime** server and a personal **API token**
  (in SolidTime: *Profile Settings → API Tokens → Create*).

## Getting started

1. Open `Timezen.xcodeproj` in Xcode.
2. Select the **Timezen** scheme and an iOS Simulator (or your device).
3. Set your **Team** under *Signing & Capabilities* for a physical device.
4. Build & Run (⌘R).
5. On first launch, enter your SolidTime server URL and API token.

### Regenerating the project (optional)

The Xcode project uses **file-system–synchronized groups**, so any `.swift` file added under
`Timezen/` is picked up automatically. To regenerate from scratch, an
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec is included: `xcodegen generate`.

## Project layout

```
Timezen/
├─ TimezenApp.swift        App entry point (@main)
├─ Info.plist              Bundle config + App Transport Security
├─ Assets.xcassets         Accent color + app icon
├─ Models/                 Codable models mirroring the SolidTime API
├─ Networking/             APIClient (async REST wrapper) + Keychain
├─ State/AppState.swift    @MainActor store: session, data, timer, theme
├─ Utils/                  Formatters, hex colors, appearance
└─ Views/                  SwiftUI screens (Home, Dashboard, Settings, edit, pickers, login)
fastlane/                  Fastlane lanes (beta → TestFlight, release → App Store)
.github/workflows/         CI: build + upload to TestFlight on version tags
```

## API notes

Targets the SolidTime v1 REST API (`<host>/api/v1/...`) with `Authorization: Bearer <token>`.
Key endpoints: `GET /users/me`, `GET /users/me/memberships`,
`GET /users/me/time-entries/active`, `GET|POST|PUT|DELETE /organizations/{org}/time-entries`
(history filtered by `member_id`; date ranges via `start`/`end`), and
`GET /organizations/{org}/{projects,tasks,tags,clients}`.

## Release & CI/CD

See [`RELEASE.md`](RELEASE.md) for TestFlight/App Store setup and the GitHub Actions + Fastlane
pipeline (required secrets, `match` signing, and how releases are triggered).
