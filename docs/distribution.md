# Distribution — plan

Goal: make Gitrasil something a person can download and run as a normal application, found in
Spotlight, and give the maintainer a way to ship updates to the people who've downloaded it. It
began as a terminal-only tool run with `scripts/run-wallpaper.sh`: a bare SwiftPM executable, with
no bundle, version, icon or signature.

Researched in October 2026 (macOS 26.6, Xcode 27, Swift 6.4). Apple's and Homebrew's rules change;
the dates below say when each fact was true.

**Status.** Built as far as it goes without a paid Apple Developer account: `scripts/build-app.sh`,
`scripts/package-app.sh`, `scripts/notarize.sh`, `.github/workflows/release.yml`, launch at login and
an opt-in update check in the menu. The bundle identifier is settled; what's left is under
*Decisions* (the end of this file).

## Recommendation

Ship an **ad-hoc signed `Gitrasil.app`**, zipped (and as a DMG), attached to **GitHub Releases** by a
workflow that runs when a version tag is pushed; tell people to drag it to Applications and, once,
click *Open Anyway* in System Settings. Updates are an **opt-in daily check of the Releases API**
that adds a *Gitrasil 0.2.0 Is Available* item to the menu, which opens the release page. No keys,
no hosting beyond GitHub, nothing to lose, nothing that phones home unless asked.

This needs one thing first: **the downloads have to be public.** On a private repository, releases
(and the Releases API) are visible only to collaborators. `HighDynamics/gitrasil` is therefore made
public under the MIT licence; the workflow keeps a switch for publishing releases to a separate
public repository instead (below).

If Gitrasil spreads past a few friends, or the *Open Anyway* step on every update gets old, join the
Apple Developer Program ($99 a year), turn on the workflow's Developer ID and notarization steps, and
move updates to Sparkle 2, which then installs them in place. Nothing built now has to be undone for
that: the bundle, version, packaging and workflow are the same, with signing switched on.

## The app bundle

### Layout

```
Gitrasil.app/Contents/
  Info.plist
  PkgInfo                       APPL????
  MacOS/Gitrasil                the GitrasilWallpaper executable, universal (arm64 + x86_64)
  Resources/AppIcon.icns
  Resources/MenuBarIcon.pdf     SwiftPM's resources, copied flat (below)
  _CodeSignature/CodeResources  written by codesign
```

SwiftPM can't make a `.app`; a script assembles one from the release build. That is the usual answer
for a single-target menu-bar app and keeps `swift build`, `swift test` and the CLI aids exactly as
they are. An Xcode project would bring asset catalogs (and Icon Composer's `.icon`, below), a GUI for
signing and archiving, and Xcode's own export for notarization, at the cost of a second build
description to keep in step with `Package.swift` (and `.gitignore` already shuts out `*.xcodeproj`).
**Keep SwiftPM and a script**; revisit only if the app grows extensions, an XPC helper or
entitlements that want Xcode's build settings.

**Resources.** `MenuBarIcon` reads its PDF through `Bundle.module`, SwiftPM's generated accessor.
With Swift 6.4's build system the accessor looks in `Bundle.main.resourceURL` (so a resource bundle
in `Contents/Resources` is found), but older toolchains' native build system only looks beside the
executable's bundle (`Gitrasil.app/Gitrasil_GitrasilWallpaper.bundle`, where code signing refuses
unsealed content) and then `fatalError`s. So the script copies the resources flat into
`Contents/Resources` and `MenuBarIcon` asks `Bundle.main` first, falling back to `Bundle.module` for
the bare executable. That holds on any toolchain, the CI runner's included.

**Universal.** `swift build --arch arm64 --arch x86_64` builds one fat binary (it takes about 30 s
here, twice the native build). macOS 26 is the last release for Intel Macs, and a friend may still
have one, so the app is universal.

### Info.plist

Written from `packaging/Info.plist` with the version filled in:

| Key | Value | Why |
| --- | --- | --- |
| `CFBundleIdentifier` | `io.github.highdynamics.Gitrasil` | Fixed for good after the first release: login items, privacy grants and updates are tied to it. Deliberately not `com.gitrasil.background`, the defaults suite: a suite can't share the app's own identifier. |
| `CFBundleName`, `CFBundleDisplayName` | `Gitrasil` | What Spotlight and Finder show. |
| `CFBundleExecutable` | `Gitrasil` | |
| `CFBundleShortVersionString`, `CFBundleVersion` | from `VERSION` | One source of truth (below). |
| `LSUIElement` | `true` | A menu-bar app: no Dock icon and no app menu, from the first frame (the code also sets `.accessory`, which alone would flash a Dock icon at launch). |
| `LSMinimumSystemVersion` | `14.0` | The package's floor (Observation). |
| `CFBundleIconFile` | `AppIcon` | |
| `LSApplicationCategoryType` | `public.app-category.developer-tools` | |
| `GitrasilReleasesRepository` | `HighDynamics/gitrasil` | Where the update check looks (set by the build, so a separate releases repository is one setting). |

**Version.** `VERSION` at the top of the repository holds `0.1.0`. The build script writes it into
both version keys; the release workflow refuses a tag that isn't `v` + `VERSION`; the app reads its
own version from the bundle. A release is: bump `VERSION`, commit, tag `vX.Y.Z`, push the tag.

### Icon

`scripts/draw-icon.swift` already draws the Gitrasil tree (the menu-bar template, and a colour
version, copper on a paper tile, in `docs/yggdrasil/icon-colour.png`). It now also writes an
`.iconset` of the colour version at every size, which `iconutil` turns into
`packaging/AppIcon.icns` (committed, like `MenuBarIcon.pdf`).

macOS 26 puts an icon that isn't the standard rounded square inside a grey one ("icon jail"). The
tile already sits on Apple's grid (an 824 pt rounded square, 22.5% corners, on a 1024 pt canvas), so
it's taken as a proper icon: checked on macOS 26.6, Finder shows it with no grey tile, and with the
dark icon style on it even draws a dark version (the copper tree on a dark tile). A Liquid Glass icon (Icon Composer's `.icon`, compiled by `actool` into
`Assets.car`) would be the full macOS 26 treatment; it needs Xcode's tools and gains little for a
menu-bar app that's rarely seen outside Finder and Spotlight.

### Signing

On Apple silicon every executable has to be signed to run at all, so an unsigned app isn't an option;
**ad-hoc** (`codesign --sign -`) is the floor. It proves the bundle hasn't changed since signing,
but names no one, so Gatekeeper treats it like an unsigned download. The script signs ad-hoc by
default and with a Developer ID when `CODESIGN_IDENTITY` names one, adding the hardened runtime and
a secure timestamp (both required for notarization). No entitlements are needed: Gitrasil isn't
sandboxed, and running `git` as a child process needs no exception.

## What a downloader sees

Browsers (and AirDrop, Mail, Messages) mark a download *quarantined*. On first launch Gatekeeper
checks it:

- **Ad-hoc signed (or unsigned)**, macOS 15 and later: *"Gitrasil" Not Opened — Apple could not
  verify "Gitrasil" is free of malware…*, with only *Done* and *Move to Trash*. Since Sequoia,
  Control-click → Open no longer gets past it. The way through is **System Settings → Privacy &
  Security**, where *"Gitrasil" was blocked…* has an **Open Anyway** button (it asks for an admin
  password and confirms once more). After that it opens normally — until the next version, which is a
  new download and asks again. The Terminal alternative is
  `xattr -dr com.apple.quarantine /Applications/Gitrasil.app`. (Checked: `spctl --assess` rejects a
  quarantined copy of the built zip's app.) A quarantined app run straight from
  Downloads is also *translocated* (run from a random read-only path), which breaks launch at login;
  moving it to Applications first avoids that, and the menu says so.
- **Developer ID signed and notarized** (ticket stapled): *"Gitrasil" is an app downloaded from the
  Internet. Are you sure you want to open it?* → **Open**. Once, and no System Settings trip.

### What Developer ID and notarization need

- **Apple Developer Program**, $99 (US) a year, enrolled as an individual with an Apple Account
  with two-factor authentication (an organisation also needs a D-U-N-S number). Lapsing doesn't
  revoke releases already notarized, but new ones can't be signed.
- A **Developer ID Application** certificate (made by the account holder in the developer site or
  Xcode), exported as a `.p12` with a password for CI.
- **Notarization** with `xcrun notarytool`, authenticated either by an **App Store Connect API key**
  (a `.p8` file, its key ID and the issuer ID; preferred for CI) or by Apple ID + an
  **app-specific password** + team ID. Hardened runtime and a secure timestamp on every signed
  binary; then `xcrun stapler staple` so the ticket travels with the app (offline first launch).
  A zip can't be stapled, so the app is stapled before zipping; a DMG is signed, notarized and
  stapled itself.

The workflow has these steps written and switched off (below). They're untested: they need the
certificate and key to run.

## Packaging and hosting

- **Zip** (`ditto -c -k --keepParent`, which keeps the signature's extended attributes): the
  smallest, opens with a double-click in Finder. The primary download.
- **DMG** (`hdiutil`, UDZO, with an Applications shortcut to drag onto): the familiar Mac install,
  cheap to make, so it's attached too. Unsigned, it opens without complaint; the app inside is
  checked at launch.
- **GitHub Releases** host both, plus a `SHA256SUMS`. Free, versioned, and what the update check
  reads. The workflow makes the release as a **draft**, so the notes can be read before it is published;
  drafts are invisible to the Releases API, so the update check only sees published releases.
  macOS runners cost 10× minutes on a private repository (a release is a few minutes; GitHub Free has
  2,000 a month); on a public one they're free.
- **Homebrew cask.** Since 2026-09-01 the official `homebrew/cask` disables casks that fail
  Gatekeeper, and Homebrew 5 removed `--no-quarantine`, so an ad-hoc app can only go in the maintainer's own
  tap (`HighDynamics/homebrew-tap`, then `brew install highdynamics/tap/gitrasil`). It still installs
  quarantined, so the *Open Anyway* step remains (or the cask strips the attribute in a `postflight`,
  which Homebrew discourages). With Developer ID and notarization a cask is pleasant, and
  `brew upgrade` becomes an update channel; official `homebrew/cask` also wants a notable, public
  project. **Not now**; a tap is a few lines once releases are signed.

## Launch at login

`SMAppService.mainApp` (macOS 13+) registers the app itself as a login item; no helper, no launch
agent. It needs a real bundle, which is why the bare executable never offered it. The menu has an
**Open at Login** toggle, off by default: registering turns it on, unregistering off, and the tick
follows `status`, so turning it off in System Settings → General → Login Items shows here too. If
macOS wants approval (`requiresApproval`) the toggle opens that pane, and until it's allowed the item
shows half on (a dash), where a click takes the request back. It's hidden when running the bare
executable. It's disabled (unless already on, so it can be turned off) while the app runs from
somewhere a login item would lose it: translocated, or straight from the mounted DMG in `/Volumes`,
gone on eject; the item's tip says to move it to Applications.

Ad-hoc signing: reports differ (some say registration works, some report an invalid-signature error
or a silent no-op), and Apple doesn't document it. Login items are identified by code signature,
and an ad-hoc signature changes with every build, so even where it works **a new version may drop
off the list or need turning on again**. It couldn't be tried here without adding a real login
item, which wasn't done here; how to try it is in *Trying it*. Any error is shown in an alert.
With Developer ID the item is identified by team and survives updates.

## Updates

| | Sparkle 2 | Releases API check (built) | Homebrew cask upgrades |
| --- | --- | --- | --- |
| What the user gets | "A new version is available" with notes; *Install* replaces the app in place and relaunches. | A menu item naming the new version; it opens the release page to download. | `brew upgrade` |
| Gatekeeper on update | None: Sparkle installs the update without quarantine. | The *Open Anyway* step again, each version (until Developer ID). | As the download (quarantined). |
| Needs from the maintainer | An **EdDSA key pair** (`generate_keys`; the private key in their Keychain and, for CI, a secret; lose it and existing installs can't verify updates again), the public key in Info.plist, an **appcast** feed (`generate_appcast`) hosted somewhere public: GitHub Pages (free on a public repo) or a release asset. A new dependency (Sparkle.framework, embedded and signed in the bundle). | A public place for releases. Nothing else. | A tap repository and a cask file per release (automatable). |
| Privacy | Fetches the appcast on a schedule (opt-in prompt on second launch, by default). | One unauthenticated GET to `api.github.com`, at most daily, only when ticked; the request carries only `User-Agent: Gitrasil/<version>` (and a fixed `Accept-Language: en`, so the locale isn't sent). | None from the app. |
| Works ad-hoc | Yes (EdDSA alone verifies), though each update's new ad-hoc signature resets login items and privacy grants. | Yes. | Yes, with the quarantine caveat. |

**Built: the Releases API check**, because it needs nothing beyond the repository itself and a few
friends can live with a download link. In the menu, under the version: **Check for Updates Daily**
(off by default; turning it on checks at once if a day has passed) and **Check for Updates Now**
(an alert says what it found). A daily check runs at launch when due and then every few hours asks
whether a day has passed (`NSBackgroundActivityScheduler`, which lets macOS pick a quiet moment). A
newer published release puts **Gitrasil X.Y.Z Is Available** at the top of the menu, kept between
launches until the running version catches up. The logic (version order, parsing the API's reply,
"due", what's remembered) is in `GitrasilCore/Updates` and unit-tested.

Known limits, left as they are:

- **Latest by date.** `releases/latest` is the most recently *created* published release, not the
  highest version. Publishing a fix to an older line (a 0.1.1 after a 0.2.0) would hide 0.2.0 from
  the check until the next release. Release in version order, or mark such a fix a pre-release.
- **Tags are `v` + `VERSION`.** The workflow refuses any other tag, and the menu's release link is
  made as `releases/tag/v<version>`.
- **A failed check waits a full day**, like a successful one (offline at the moment, a rate limit):
  nothing retries sooner. *Check for Updates Now* is always there.
- **A separate releases repository needs at least one commit**, for `gh release create` to make the
  tag on.

Sparkle is the move once releases are notarized: in-place updates, and Sparkle then also checks
the Apple signature matches. Switching keeps `VERSION`, the bundle and the workflow; it adds the
framework, the key and an appcast step.

## The release workflow

`.github/workflows/release.yml` runs when a tag `v*` is pushed (or by hand, run on the tag). Every
action is pinned to a commit, and checkouts keep no credentials. Three jobs:

1. **build**, which sees no secrets: checks it's running on a tag, the tag is `v` + `VERSION`, and
   the tagged commit is on `main`; runs the tests; `scripts/build-app.sh` (universal, ad-hoc), then
   `scripts/package-app.sh` (zip, DMG, `SHA256SUMS`).
2. **sign**, only when signing is on (below), in the `release` environment: builds again with the
   Developer ID, notarizes and staples the app, packages, and signs, notarizes and staples the DMG.
   The identity and the API key reach only the steps that use them.
3. **publish**: puts the signed files (or, with signing off, the ad-hoc ones) on a **draft**
   release with install notes and generated release notes. Run again, it replaces a draft's files,
   and refuses if the release is already published.

With no secrets it does the ad-hoc path. Two switches, both off:

- **Developer ID** — repository variable `MACOS_SIGNING` = `true`, and in the `release`
  environment the secrets `DEVELOPER_ID_P12` (base64 of the `.p12`), `DEVELOPER_ID_P12_PASSWORD`,
  `NOTARY_KEY_P8` (base64 of the `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. Then the sign job
  imports the certificate into a throwaway keychain, signs with it, and notarizes and staples
  (`scripts/notarize.sh`).
- **Separate public releases repository** — repository variable `RELEASES_REPO` (for example
  `HighDynamics/gitrasil-releases`, which needs one commit) and secret `RELEASES_TOKEN` (a
  fine-grained token with *Contents: write* on that repository only). Then the release is made there
  and the app's update check looks there.

**Before turning signing on** (nothing here is set up on GitHub yet). The workflow's checks run in
the workflow file, which anyone who can push a branch could change; these settings hold whatever the
file says:

1. Create the environment **`release`** (Settings → Environments), with *Deployment branches and
   tags* set to *Selected* and one rule, tags matching `v*`. Put the five signing secrets in it, not
   in the repository's secrets. Only a run on a `v*` tag can then reach them.
2. Add a **tag ruleset** (Settings → Rules → Rulesets → New tag ruleset) for `v*`, restricting
   creation, update and deletion to the repository owner (bypass list: repository admin), so nobody else can make
   the tag the environment trusts.
3. Then set `MACOS_SIGNING` to `true`.

On GitHub Free, environments (and their secrets and rules) exist only in **public** repositories,
which would have needed GitHub Pro for a private one; with this repository public that no longer
applies. `RELEASES_TOKEN` is a repository secret the publish job reads; with a
separate releases repository, the ruleset in step 2 matters for it too.

## Trying it

```bash
scripts/build-app.sh                    # dist/Gitrasil.app (universal, ad-hoc signed; about 30 s)
open -n --env GITRASIL_BACKGROUND_DEFAULTS_SUITE=gitrasil-try dist/Gitrasil.app
#   a throwaway suite (no pins); plain `open dist/Gitrasil.app` uses your own pins, so quit the
#   terminal instance first or there are two backgrounds and two menu-bar trees
scripts/package-app.sh                  # dist/Gitrasil-0.1.0.zip, .dmg, SHA256SUMS
scripts/build-app.sh --install          # also copies it to /Applications, replacing an earlier copy
defaults delete gitrasil-try            # afterwards, the throwaway suite
```

`open` doesn't hand the shell's environment to the app; `--env` passes a variable.

- **Spotlight** indexes an app wherever it is in an indexed folder, but not under a hidden one: built
  in a worktree in `.claude/`, `mdls` reads the app's metadata (kind Application, name Gitrasil) but
  `mdfind` doesn't find it. After `--install` (or built in the main checkout's `dist/`), type
  *Gitrasil* in Spotlight; `mdfind "kMDItemCFBundleIdentifier == 'io.github.highdynamics.Gitrasil'"` shows
  where it's indexed.
- **Gatekeeper, as a downloader sees it**: download the zip from a draft release in a browser (or
  `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" Gitrasil.app` on a copy),
  then open it.
- **Launch at login**: from `/Applications`, tick *Open at Login*, check System Settings → General →
  Login Items, log out and in; then untick it. If it errors with the ad-hoc signature, that's the
  answer: it waits for Developer ID. (Before registering, `SMAppService.mainApp.status` reads
  *not found* for the ad-hoc app in `dist/`, which the menu shows as unticked; the launch log says
  `open at login not found`.)
- **Update check**: before the first release (or with the repository private), *Check for Updates
  Now* says no release was found. `--env GITRASIL_RELEASES_REPOSITORY=<owner/name>` points the check
  at another repository to see the found-a-newer-one path: checked here against
  `sparkle-project/Sparkle`, whose 2.10.0 the app took for a newer Gitrasil and kept in the suite
  (`availableRelease`), with daily checks turned on in the throwaway suite beforehand.

## Decisions

Made (October 2026):

1. **Where downloads live** — `HighDynamics/gitrasil` is public, under the MIT licence (`LICENSE`).
   Releases are attached to it, and the update check reads them.
2. **Signing** — ad-hoc, with the *Open Anyway* step on first launch. No Apple Developer Program
   yet; join if more than a handful of people use it, then switch on Developer ID and notarization.
3. **Updates** — the built opt-in daily check of the Releases API (*Updates*, above). Sparkle with
   Developer ID, later.
4. **Homebrew** — no cask yet; a personal tap once releases are notarized.
5. **Bundle identifier** — `io.github.highdynamics.Gitrasil` (reverse-DNS of the owner's GitHub
   Pages domain, the convention for an app with no domain of its own). It is permanent after the
   first release, so it was settled before the first tag. It lives in `CFBundleIdentifier` in
   `packaging/Info.plist` and in the update check's scheduler identifier in `AppServices.swift`. The
   defaults suite stays `com.gitrasil.background`, so pins and settings saved before the change
   carry over.
