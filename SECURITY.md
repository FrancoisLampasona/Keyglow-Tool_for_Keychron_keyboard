# Security and privacy

Keyglow is a local macOS keyboard utility. It has no account service, telemetry, or cloud profile storage. Profiles and backups can contain personal macros; treat them as private files even when exported as JSON.

The Bluetooth RGB protocol is experimental. It uses normal HID output indicators, a frame checksum, and device-side validation. A checksum detects corruption; it does not authenticate a sender or turn the channel into a secure firmware update transport. The current firmware has no supported Bluetooth update path.

The app must not request broad permissions to work around a missing hardware protocol. Input Monitoring is granted by the user through macOS. Firmware changes must preserve a recoverable boot path and validate a complete image before installation; host tests alone are insufficient to enable flashing in a release.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** option if it is available. If private reporting is unavailable, open a minimal issue asking for a private contact route, without exploit details or private data. Do not attach device backups, macro profiles, serial numbers, Bluetooth addresses, signing material or macOS permission databases.

Include the app revision, keyboard model, connection mode and a synthetic reproduction where possible. Explain whether the issue was observed on hardware or in a host test. There is no guaranteed response or support period; fixes are maintained on the current development branch.
