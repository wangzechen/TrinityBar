# Releasing TrinityBar

**Rule: nothing release-related happens until every change for the version is finished and fully tested.** That means no edits to `version.env`, no `v*` tag, and no draft release until all of steps 1–4 pass on the exact commit you intend to ship.

---

## 1. Development complete
- [ ] Every change planned for this version is merged on `main`, and nothing is waiting in another branch or session.
- [ ] Each behavior change updated README / ARCHITECTURE **in the same commit** (see step 3 for the final review).
- [ ] The working tree is clean: `git status` shows nothing.

## 2. Automated checks
Run locally, in order. Each must pass with **zero warnings**:

```zsh
./scripts/build_app.sh     # shipped single-module swiftc build, strict concurrency, warnings as errors
./scripts/check_docs.sh    # README tree, no hard-coded versions, documented sizes (needs the build above)
swift build
swift test
```

- [ ] All four pass locally.
- [ ] The **CI** workflow is green on the same `main` commit (`gh run list --workflow ci.yml --limit 1`).

## 3. Docs review
`check_docs.sh` only catches mechanical drift. Read what changed since the last release and confirm the prose still matches:

```zsh
git diff --stat "$(git describe --tags --abbrev=0)"..HEAD
```

- [ ] **README → Features / Quick Interactions**: every user-visible change is described, and nothing removed or renamed is still advertised.
- [ ] **README → Project Structure**: new, renamed, or removed files and their one-line descriptions are current.
- [ ] **ARCHITECTURE §2.x**: every changed module's description (data sources, timers, threading, layout conventions) matches the code.
- [ ] **ARCHITECTURE §3 Extension Guide**: still the right steps if a change altered how modules are added.
- [ ] **Sizes**: the `~N KB` figures in README / ARCHITECTURE match the new build (`check_docs.sh` enforces ±10%; round to the real value if it drifted).
- [ ] **Screenshots**: if the dashboard UI changed, regenerate them with `./scripts/capture_screenshots.sh` and review them (ARCHITECTURE §2.5).

## 4. In-app checks
Quit the installed copy first (`Quit TrinityBar`, so native icons restore), then run `open dist/TrinityBar.app`.

- [ ] **Panel position**: clicking the emblem opens the panel directly below it, inside the screen edges. An outside click closes it, and so does `Esc`.
- [ ] **Scroll-to-volume**: scrolling over the emblem and over the Summary page changes volume smoothly. `⌥`-click toggles mute.
- [ ] **Keep Awake**: choosing `30m` shows `Awake · 29:59` ticking every second in both the button and the collapsed header badge, with no panel height jitter. Close the panel for more than 1 minute and reopen it: the time is correct immediately. `1h` shows `0:59:59`. Turning it off clears the badge.
- [ ] **Each module**: Battery / Network / Sound summary cards and drill-down pages show live values.
- [ ] **Feature-specific**: exercise everything this version changed.
- [ ] **Quit restore**: quitting brings back the native Wi-Fi / Battery / Sound icons.

Afterwards, relaunch the installed copy: `open /Applications/TrinityBar.app`.

If anything fails, fix it on `main` and restart from step 1.

---

## 5. Version bump
Only after steps 1–4 pass:

1. Edit `version.env`: set `MARKETING_VERSION` (semver: patch for fixes and small polish, minor for new features) and increment `BUILD_NUMBER` by one.
2. Commit it alone as `Release vX.Y.Z`, push to `main`, and wait for CI to go green.

## 6. Tag & draft release
```zsh
git tag -a vX.Y.Z -m "TrinityBar vX.Y.Z"
git push origin refs/tags/vX.Y.Z
```

The **Release** workflow checks that the tag matches `version.env`, builds `--release`, and creates a **draft** release with the `.zip` and `.sha256`.

- [ ] The workflow succeeded (including **Attest build provenance**), and the draft has both assets.
- [ ] Replace the auto-generated notes with notes in the template below: `gh release edit vX.Y.Z --notes-file notes.md`.

## 7. Publish (manual)
- [ ] Review the draft on GitHub, then click **Publish release**.
- [ ] Update your own `/Applications/TrinityBar.app` to the released build.

### If something is wrong after tagging
- **Draft not yet published**: delete the draft (`gh release delete vX.Y.Z --yes`) and the tag (`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`), fix the problem on `main`, and redo steps 1–6.
- **Already published**: never move or delete the tag. Ship the fix as the next patch version.

---

## Release notes template
Match the style of earlier releases. Describe the user-visible effect, include the old behavior where it helps, and use bold lead-ins.

````markdown
## TrinityBar vX.Y.Z

A <one-phrase character of the release> release following vX.Y.(Z-1).

### Improvements & Fixes
- **<Short Title>**: <what changed for the user; what it was like before, if useful>.

### Install / Upgrade
Download **`TrinityBar-vX.Y.Z-macos-arm64.zip`**, drag **`TrinityBar.app`** to **`/Applications`**, and run once:
```zsh
xattr -cr /Applications/TrinityBar.app
open /Applications/TrinityBar.app
```

**Full Changelog**: https://github.com/wangzechen/TrinityBar/compare/vPREV...vX.Y.Z
````
