# CI quality checks

What Gitrasil's checks are, why those, and what was left out. Run them with `scripts/check.sh`
(see the README); CI runs the same commands.

## What the repo is built with

- Swift, one SwiftPM package (`swift-tools-version:5.9`, macOS 14 floor, Swift 5 language mode),
  about 7,900 lines in 45 files: `GitrasilCore` (platform-agnostic logic), `GitrasilWallpaper`
  (AppKit/SwiftUI desktop window and drawing), `GitrasilTestSupport` (real fixture git repos) and
  `GitrasilCoreTests` (110 XCTest tests).
- **No third-party dependencies.** `Package.swift` has no `dependencies`, so there is nothing to
  audit and no `Package.resolved`.
- It is a macOS-only app (AppKit, FSEvents, Observation), so CI needs a macOS runner. The tests need
  no display, no secrets and no user defaults: they build git repos in temp dirs and shell out to
  `git`, which the runner image has.
- The code is written densely and by hand: one-line `if`/`guard` bodies, long geometry
  expressions, one-letter maths names, comments wrapped at about 100 columns.
- Before this work there was no formatter, linter or CI.

## Candidates by layer

| Layer | Candidates | Chosen |
| --- | --- | --- |
| Formatting | SwiftFormat (Nick Lockwood), swift-format (Apple) | **SwiftFormat 0.63.1** |
| Linting | SwiftLint, swift-format's lint mode | **SwiftLint 0.65.1** |
| Static analysis | compiler warnings as errors, `swiftlint analyze`, Xcode static analyzer | **`-warnings-as-errors`** |
| Tests | `swift test` | **`swift test`** |
| Dependency or security audit | `swift package show-dependencies`, Dependabot, OSV | none needed |

### Formatting: SwiftFormat

- **swift-format** ships in the toolchain, but its version follows whichever Xcode is installed
  (this machine's is a dev build, a CI runner's is another), so the same file can pass in one place
  and fail in another. It has no standalone release binary to pin.
- **SwiftFormat** publishes a release zip per version, which `scripts/install-tools.sh`
  downloads, checks against a pinned SHA-256 and runs. Local and CI results are identical and
  independent of Xcode. It is also the more configurable of the two, which this codebase needs.
- Its defaults would rewrite 2,200 spots across every file, mostly by wrapping the dense one-line
  bodies and long lines. That churn finds nothing, so `.swiftformat` turns off the re-wrapping
  rules and the rules that change intent rather than layout (`redundantSelf`, `hoist*`,
  `noForceUnwrapInTests`, ...). What remains checks trailing commas, consecutive spaces, blank lines
  between scopes, modifier order and trailing whitespace; the first run changed 32 lines in 19
  files. `indent` is off too: its few changes were to hand-aligned continuation lines and one
  multi-line string. Each disabled rule has a reason in the config.

### Linting: SwiftLint

- The standard Swift linter, actively maintained, with a portable release binary to pin.
- Defaults flagged 549 things, but 59 were SwiftPM's generated files under `.build` (now
  excluded). Of the 490 real ones, about 280 were one-letter names in geometry code and 165 were
  lines over 120 characters. The config keeps the rules but sets thresholds for the codebase:
  one-letter names allowed (`identifier_name.min_length: 1`), line length 150, and size and shape
  metrics (file, type and function length, parameter count, complexity, tuple size) raised to
  ceilings just above today's worst case. Each has a reason in `.swiftlint.yml`: shrinking drawing
  code to satisfy a counter is a behaviour-risking refactor, but a runaway function should still
  trip.
- A few opt-in rules that catch real mistakes were added (`empty_count`, `first_where`,
  `contains_over_first_not_nil`, `sorted_first_last`, `fatal_error_message`, `overridden_super_call`).
- It runs with `--strict`, so a warning fails the check.
- One case worth knowing: `redundant_discardable_let` wants `_ = x` for `let _ = x`, but in
  `WallpaperView`'s `ViewBuilder` bodies `_ = x` is parsed as a view and does not compile.
  Those two lines carry a narrow `swiftlint:disable:next` with that reason.
- Rejected: **`swiftlint analyze`** (needs a full compiler log; its `unused_import` and
  `unused_declaration` rules are slow and noisy for the value on a codebase this size).

### Static analysis: the compiler

- `swift build -c release -Xswiftc -warnings-as-errors`. The compiler's own diagnostics (unused
  results, deprecations, concurrency warnings) are the most accurate analysis available for Swift,
  cost nothing extra and the code is clean today. The release configuration is the one
  `scripts/run-wallpaper.sh` ships, so release-only compile problems surface too.
- Not adopted: Swift 6 language mode or `-strict-concurrency=complete`. It is a migration, not a
  check, and would be a separate piece of work.
- Rejected: the Xcode static analyzer (`xcodebuild analyze`), which wants an Xcode project this
  package deliberately does not have (`*.xcodeproj` is gitignored).

### Tests: `swift test`

The existing 110 tests, unchanged. No display or secrets are needed. Not added: coverage gates
(a threshold on a personal project would invite tests written for the number).

### Dependency and security audit

Nothing to audit: no dependencies. If one is ever added, enable Dependabot's `swift` ecosystem and
revisit. The GitHub Actions used are pinned by commit SHA; Dependabot's `github-actions` ecosystem
would keep those current, but it is left out here to keep the set small.

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, with four jobs
that are separate checks so each can be required: **Format**, **Lint**, **Build**, **Test**.

- Runner `macos-26` (Apple silicon), with Xcode 26.6 selected explicitly through `DEVELOPER_DIR`
  rather than the image default. The package floor is macOS 14, and Xcode 26.6 supports tools
  version 5.9.
- Actions are pinned to commit SHAs; the permissions are read-only `contents`; no secrets are used.
- Caching: the downloaded tools (keyed on `scripts/tool-versions.sh`) and `.build` for the build
  and test jobs (keyed on the sources, falling back to the newest earlier cache).
- A pushed commit cancels the previous run on the same PR, never on `main`.

## Updating the tools

Edit `scripts/tool-versions.sh`: change the version and its SHA-256 (`shasum -a 256` of the
release zip) together. Running `scripts/check.sh format` locally then reinstalls the new version.
