# Interface languages

Keyglow supports **Italiano**, **English** and **Français**. Choose a language from the globe menu in the first-run assistant or the sidebar footer. The interface updates without restarting, and the choice persists on the Mac. Italian is the initial default.

The language applies to app-owned navigation, controls, instructions, status messages, tooltips and accessibility labels. Dates use the selected locale. It does not change the physical Italian ISO legends, keycodes, profile names, macro text, filenames or website addresses. Permission windows and file-dialog controls owned by macOS may use the system language.

## Translation resources

- `macOS/Resources/Localization.json` maps canonical Italian presentation strings to `en` and `fr` translations. Italian is the source and fallback.
- `macOS/Sources/Localization.swift` resolves exact strings and parameterized messages. Missing entries retain the source string.
- `macOS/Sources/LocalizationViews.swift` provides observing SwiftUI text/control wrappers and the language menu. `AppLanguageStore` saves `app.language` and notifies native menus and the setup window when it changes.
- `macOS/Resources/{it,en,fr}.lproj/InfoPlist.strings` supplies the Bluetooth usage explanation for macOS.

Resources ship inside the application bundle. The app does not contact a translation API or upload strings, profiles or typing.

## Adding or changing text

Add both English and French entries when introducing an app-owned Italian label or message. Use `LText`, `LLabel`, `LButton` and the other localization wrappers for SwiftUI, and `L10n.string` for app-owned AppKit text. Use the localized help/accessibility modifiers for translated descriptions.

Render user-supplied values verbatim. A profile called “Colore” must still be called “Colore” in English and French, including its tooltip and accessibility actions. Do not replace stored enum values, firmware command names or keyboard identity strings with translated values. Translated key-action names participate in search without changing their codes.

Parameterized catalog entries use `{0}`, `{1}` and so on. Preserve every parameter in both translations; parameters may move to suit the language. Parameter contents remain verbatim except for the small explicit allowlist of app-owned fragments in `AppLocalizer`. Do not add user names or paths to that allowlist. Prefer unambiguous templates; adjacent parameters can be impossible to separate reliably. Use `L10n.format` with explicit arguments for composite labels whose arguments can contain delimiters; arguments are inserted verbatim. Use actual line breaks in the decoded translation value: encode them as `\n` in JSON, not as the double-escaped text `\\n`.

To inventory Swift strings for review:

```sh
python3 scripts/localization/extract.py
```

The output is `build/localization-inventory.json`. It includes protocol identifiers and other non-display strings, so it is a review aid, not an automatic translation list. Never translate everything in it blindly.

Run the catalog regression checks:

```sh
zsh scripts/test-localization.sh
```

They check locale parity, parameter preservation, Unicode, fallback, user-name preservation, firmware-step messages and preference persistence. Also build the app and inspect actual English and French pages at 900 × 640 and 1400 × 900, including the first-run assistant, long firmware instructions, menus, errors and empty states. Switch back to Italian and verify that the same draft and user data remain. Automated string checks do not replace layout or accessibility testing.
