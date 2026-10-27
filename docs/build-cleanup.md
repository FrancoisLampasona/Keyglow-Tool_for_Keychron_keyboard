# Cleaning local build outputs

Old app bundles in this checkout can appear as multiple Keyglow entries in macOS. The build script now saves the previous complete app as a verified ZIP in the ignored `build/recovery/apps` directory. It does not retain another `.app` directory.

The HID probe builder uses the same archive helper. If its existing process is running or cannot be checked, it archives the new candidate and leaves the installed probe untouched. After closing the probe, rerun its build command with `--replace-closed`. Successful replacements archive the previous probe before the atomic bundle swap.

Preview the exact cleanup allowlist first:

```sh
python3 scripts/clean-builds.py
```

Close any obsolete diagnostic app, and wait for builds/tests to finish. Apply the app cleanup or the complete allowlist:

```sh
python3 scripts/clean-builds.py --scope apps --apply
python3 scripts/clean-builds.py --apply
```

For each recognized obsolete bundle, cleanup creates a ZIP, verifies every source file against its archived copy, unregisters only that old path from LaunchServices, then removes the original bundle. The history records the original relative path, executable digest and archive. It does not reset Launchpad or change macOS privacy permissions. macOS may take time to refresh its app list.

The current `dist/Keyglow.app`, all `research` data, `dist/firmware`, the entire OTA integration directory, diagnostic firmware, QMK checkout, Python environment and Arm toolchain are preserved. Unknown app names and paths are never inferred to be disposable. Symlinked cleanup paths are rejected.

Generated Swift caches, icon intermediates and host-test executables can be recreated by their build scripts. Cleaning caches makes the next build slower. Archived apps remain available for manual recovery; verify the signature after extraction before using a recovered build. Old app permissions may no longer match its signature.

`archive-current` is an internal build helper that creates a verified backup without replacing or removing the current application. Recovery archives can contain older local diagnostic paths; keep the ignored recovery directory private, outside source publication.
