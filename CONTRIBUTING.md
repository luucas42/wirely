# Contributing to Wirely

Thanks for wanting to help. Bug reports, fixes and small focused features are all welcome.

## Getting started

```sh
brew install wireguard-go
swift test
scripts/build-app.sh && open build/Wirely.app
```

`main` is protected: fork the repo, work on a branch, and open a pull request. Keep each PR to one change — it's much easier to review.

## Before you open a PR

- `swift test` passes and `swift build` has no new warnings.
- New logic comes with tests. Most of the code is testable without root: the tunnel orchestration (`TunnelManager`) runs against fakes in `Tests/WirelyHelperKitTests`.
- **UI changes:** render the states and attach before/after images to the PR:
  `build/Wirely.app/Contents/MacOS/Wirely --render-previews /tmp/previews`
  Check both light and dark mode.
- **Strings:** every user-visible string lives in `Sources/WirelyApp/L10n` with both English and Turkish text (a test fails if one is missing). If you don't speak Turkish, add your best attempt and say so in the PR.

## Working on the helper (runs as root)

- Run system commands as an executable path plus an argument list via `CommandRunner` — never through a shell, never with interpolated strings.
- Never log private keys or the UAPI configuration text.
- Anything the helper changes on the system (routes, DNS, …) must be recorded in `PersistedState` **before** it is applied and undone in teardown and `cleanupStale()`.
- If you change helper behaviour or the app↔helper protocol, bump `HelperConstants.helperVersion` so the app asks users to update the service.

## Reporting security issues

Please don't open a public issue for vulnerabilities. Use GitHub's **Report a vulnerability** (Security tab → Advisories) so it can be fixed before details are public.
