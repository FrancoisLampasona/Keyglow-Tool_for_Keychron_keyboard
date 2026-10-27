# Stable identity for local macOS builds

An ad-hoc signature identifies a particular build by its CodeDirectory hash. Recompiling changes that identity; an enabled Input Monitoring entry can consequently refer to an older application. A stable certificate-based designated requirement lets macOS recognize successive builds. See Apple's [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) and [requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).

For local development on your own Mac, explicitly create one identity:

```sh
python3 scripts/setup-local-signing.py --create
python3 scripts/test-signing.py
```

The setup imports a non-extractable private key into the user's default Keychain, with access limited to `/usr/bin/codesign`. It keeps only the public certificate fingerprint in `~/Library/Application Support/Keyglow/Development/signing.json`. Temporary key files are removed after import. It does not modify certificate trust, Input Monitoring, Gatekeeper, or other applications' permissions. Never regenerate or delete the signing key between builds. The setup refuses to create a second similarly named certificate if the configuration is missing.

The app builder automatically uses this configured identity and pins both the unchanged bundle identifier and the exact certificate fingerprint. It verifies the candidate against the previous signed app's requirement before replacing it. A missing key, changed signer or accidental ad-hoc fallback fails the build; the previous app is retained. Close Keyglow before building. `SIGNING_IDENTITY` still selects an explicit developer certificate, but cannot silently replace an existing app with an incompatible identity.

Moving from an old ad-hoc build to this certificate may require one new macOS authorization. Existing build-specific consent cannot be silently transferred. After authorizing the first certificate-signed build, verify a later build by checking actual Input Monitoring access and a read-only HID request. An offline signature check alone does not prove TCC permission persistence.

The signature test creates temporary executables with different contents, checks their requirements in both directions, and rejects an incorrect identifier, incorrect certificate fingerprint and ad-hoc signature. It never launches the fixtures or requests keyboard access.

This is a local development identity, not Apple Developer ID or notarization. Public distribution still requires a separately managed signing and notarization process. CI without a configured identity continues producing ad-hoc development builds. No private signing material belongs in the repository or release bundles.

Input Monitoring and Keychain access are separate policies. On the development
Mac, the existing firmware-owner item also carries a Keychain partition ACL with
per-executable `cdhash` entries. A stable designated requirement alone did not
eliminate its authorization prompts after recompilation. Do not treat an Input
Monitoring success as proof that owner-key access will persist, and do not remove
the partition ACL or allow all applications as a workaround. This remaining
Keychain migration needs separate validation; consent must occur in macOS.

Local validation on the development Mac: after the one-time authorization, build 12 → build 13 retained the same certificate requirement with a changed executable hash. The second build automatically opened the Q6 Max and read its indicator state without another Settings change. The live RGB opt-in also survived restart without an RGB send at launch. This is evidence from one Mac, not a guarantee for every macOS installation.
