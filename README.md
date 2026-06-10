# ci-mobile-devloop-repro

Minimal reproduction of the **Android mobile dev-loop** from
[Expensify/melvin#172](https://github.com/Expensify/melvin/pull/172), with
melvin (the CF Worker routing, the `agent-device` skill, the Claude Code
integration, the web path) **removed**.

Goal: prove that the JS dev loop - *edit source, see it on a running emulator
without rebuilding native* - is feasible on CI.

## The loop (one GitHub Actions job)

```
boot emulator                          (reactivecircus/android-emulator-runner)
   -> download prebuilt APK            (npx rock remote-cache download, PUBLIC S3)
   -> start Metro the App's way        (npx rock start)
   -> install APK + adb reverse 8081
   -> launch app, screenshot           (01-before.png)
   -> edit ONE visible source string   (en.ts: "Phone or email")
   -> Fast Refresh, else explicit reload
   -> screenshot                       (02-after.png)
   -> upload before/after as artifact
```

## What makes it minimal (vs PR #172)

- **No secrets.** `Expensify/App` is public (no PAT) and the Rock S3 cache is
  public-read (anonymous GET, no AWS creds). Verified locally: a 110 MB APK
  downloads anonymously for App's fingerprint.
- **No native build.** The `developmentDebug` APK is fetched from the cache,
  never built. On a cache miss the job fails fast in seconds.
- **No Mapbox SDK token.** That token is only needed to *build* native; we only
  *bundle JS*, and `@rnmapbox/maps` JS is already in `node_modules`.
- **watchman is installed** so Metro's file watcher detects the edit (Fast Refresh
  on Linux CI is unreliable without it).
- **Metro is started App's way** (`npx rock start`), not the PR's
  `react-native start --config <wrapper>` (which only existed to silence LogBox).
- **Verification is just two screenshots**, uploaded as a `devloop-evidence-*`
  artifact. Eyeball `01-before.png` vs `02-after.png`.

## Files

| Path | Role |
| --- | --- |
| `.github/workflows/devloop.yml` | The single CI job (host prep + emulator). |
| `scripts/devloop.sh` | The loop, run inside the emulator action. |
| `scripts/edit-signin-label.sh` | The one source edit ("Phone or email"). |

## Run it

Push to `main`, or trigger manually:

```bash
gh workflow run devloop.yml --repo kacper-mikolajczak/ci-mobile-devloop-repro
```

Then download the `devloop-evidence-*` artifact and compare the two PNGs.

## Known risks / caveats

- **Rock cache hit depends on App's fingerprint.** App `main` publishes a
  `developmentDebug` build on every push, so a hit is expected - but there's a
  short window right after a merge while the build is still publishing. If the
  job reports a cache MISS, re-run shortly or pin the App checkout to a slightly
  older commit (`ref:` on the App checkout step).
- **Fast Refresh does not reliably propagate a translation-file edit.** Editing
  `en.ts` produces no HMR delta (it is not a component boundary), so the loop
  tries Fast Refresh first, then falls back to an **explicit reload** (force-stop
  + relaunch) which re-pulls the bundle from Metro with the edit baked in - the
  same effect as the melvin PR's `agent-device metro reload`. watchman is still
  installed so Metro re-transforms the changed module on the re-request. The loop
  polls the on-device UI (`uiautomator`) for the `CI-EDIT` token and fails if it
  never renders.
- **Emulator on GitHub-hosted runners** needs KVM; the workflow enables it. The
  cold Metro bundle compile is slow (minutes) and memory-hungry (`NODE_OPTIONS`
  raises the heap to 8 GB).
