# Guided USB first-install checks

`sh macOS/Tests/FirstInstall/run.sh` runs the production assembler/coordinator against memory-backed DFU. It never opens a device, generates a real owner credential or uses Keychain. Fixtures use a clearly public deterministic key.

Coverage: independent full readbacks, exact device identity/port binding, known source fingerprint, source/EEPROM preservation, approval hash mismatch, tampered private artifacts, staging readback rejection before loader write, interrupted loader write and explicit resume, restore capability migration and opaque macro bytes. The Swift images are compared byte-for-byte with the existing Python bootstrap assembler. `scripts/test-via.sh` also checks actual VIA setter/readback behavior for opaque backups and effect/color resets.

`sh macOS/Tests/FirstInstall/preview.sh` builds an isolated native visual fixture. It uses the actual view with synthetic states, has no installation directory or firmware resources, and cannot run an installation. Only that test build defines `KEYGLOW_UI_PREVIEW`. It does not represent physical validation. Remove its app bundle after inspection to avoid an extra Launchpad entry.
