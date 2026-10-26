# Q6 Max ISO integration review

Scope: Keychron QMK revision `2b493ff95f2665db719b1e95c91babb5036e72f3`, target `keychron/q6_max/iso_encoder`, and this project's `tastiera_bt` keymap. This is a source-level account of the RGB integration. The separate experimental OTA core is not part of the installed RGB firmware.

## Callbacks and wireless delivery

QMK calls `matrix_scan_user()` through the normal matrix scan path after debounce, including wireless operation. Keychron calls `process_record_user()` before its own key handling. The legacy reception gate uses physical matrix positions, so it does not require rewriting a VIA keymap.

Indicator delivery follows the LKBT51 driver, wireless LED state, `host_keyboard_leds()`, QMK's LED task, and `led_update_user()`. The wireless queue can coalesce nearby changes before the next observation; the sender spaces symbols by 80 ms. This source path alone does not prove radio delivery. Physical v3 validation separately confirmed green Breathing and persistence after power-off on one board, with USB disconnected.

The generated keymap adds the three callbacks from `integration-hooks.example.c`. The selected upstream keymap does not define conflicting callbacks. Integration into another keymap must preserve any existing callback behavior.

## RGB render and persistence

The Keychron keymap enables a strong `os_state_indicate()` in `rgb/keychron_rgb.c`, in addition to the generic weak implementation. The patch adds a weak filter hook to both existing renderers; the bridge supplies its strong implementation. It filters Caps/Num during recognized reception and a short restoration tail, while preserving other indicator bits and the normal renderer behavior.

Stock RGB setters ignore mode and HSV changes while disabled. Enabling can also raise brightness to the keyboard minimum. The bridge therefore enables first, then applies the complete desired mode, HSV and speed.

That ordering is insufficient by itself: Keychron's renderer reloads HSV and speed from EEPROM in each chunk of the first frame after an effect change. `rgb_matrix_set_config_noeeprom()` sets a volatile-state guard. Rendering still resets regions but skips that reload until `rgb_task_flush()` completes the frame. Normal mode, off and toggle operations cancel the guard when a manual action supersedes the change.

The bridge queues a valid v3 command and applies it in the next matrix scan, outside the LED callback. Only persistent command `04` calls `rgb_matrix_save_lighting()` and `rgb_save_retail_demo_if_changed()`. These helpers compare the existing values, update only RGB enable/mode/HSV/speed and the demo byte, preserve reserved flags, and avoid identical writes. They do not save the full configuration, keymap, macros, timers, indicator settings, per-key RGB or Mix.

Temporary v3 commands and legacy v1/v2 use RAM only. Disabling demo in RAM prevents the demo task from replacing a requested effect. Persistent v3 also saves that single demo flag so it cannot replace the effect after reboot.

Persistence uses the existing emulated EEPROM implementation. It is not a transaction guaranteed to survive loss of power during a write. Wait for transfer completion and two further seconds before switching the keyboard off.

## Connected-idle policy

The Q6 Max already defines a strong `lpm_is_kb_idle()` that checks the power-on indicator and backlight. The patch preserves both conditions and adds `q6_lpm_is_idle_user()`, whose default is weak and returns true. The project override vetoes MCU STOP only when all of these are true:

- Bluetooth is selected and the wireless state is `WT_CONNECTED`.
- The connected-idle timeout is exactly 65520 seconds, the Reattiva preset.
- Initial sampling is complete and at least one plausible battery measurement has arrived.
- The battery is neither empty nor critical and its measured voltage exceeds the upstream empty threshold.

Added getters expose the connected-idle timeout and battery validity without writing configuration. The validity flag is necessary because the upstream initial voltage is a plausible full-battery default before the first radio response. It is reset on battery initialization and set only for plausible measured values.

Other modes, disconnection, missing or low battery measurements, and any different timeout remove the additional veto. Existing sleep checks then run normally. The finite radio timeout remains a timeout; the policy does not guarantee the radio or Mac remains awake. Its battery cost and wake latency are unmeasured.

The upstream timeout setter can send a synthetic input when the physical transport is wireless. The app therefore requires the selector to be **Cable**, as well as USB connected, before applying this setting. The idle-policy component does not change that upstream setter or synthesize input.

## Configuration boundaries

The pinned source's logical EEPROM layout is:

| Region | Bytes | Inclusive offsets |
| --- | ---: | --- |
| QMK core | 37 | 0–36 |
| Language | 1 | 37 |
| Debounce | 2 | 38–39 |
| Snap Click | 60 | 40–99 |
| Custom RGB | 522 | 100–621 |
| Wireless configuration | 4 | 622–625 |
| VIA magic and layout options | 4 | 626–629 |
| Keymap: 4 × 6 × 20 × 2 | 960 | 630–1589 |
| Encoder: 4 × 1 × 2 × 2 | 16 | 1590–1605 |
| Macros | 1466 | 1606–3071 |

This describes the selected source revision, not every shipped firmware. VIA checks build-date magic and can reset keymaps and macros after a firmware rebuild. A complete firmware image also spans the emulated EEPROM sector. Neither flashing nor boot-time initialization inherits the RAM-only guarantee of a temporary RGB command. Save and restore the device configuration through a verified process when installing firmware.

## Verification boundaries

`sh firmware/test.sh` compiles host suites with ASan and UBSan. The suites cover the protocol, bridge, legacy rejection, renderer/persistence helpers extracted from the pinned source, and the connected-idle policy. Renderer tests simulate EEPROM reloads, off/on transitions, zero values, duplicate saves, and unrelated bytes. Idle tests compile the actual Q6 hook and battery snippets against simulated radio and hardware state.

`apply-qmk-patch.py --check` validates the pinned revision and expected transformations without writing; repeated application is checked for idempotence. Swift and C share protocol vectors, independently checked with Python's CRC implementation.

The physical green Breathing and power-cycle check establishes that v3 RGB worked on the tested unit. It does not validate every effect, flash power-loss recovery, radio firmware updating, battery consumption or future revisions. No firmware update over Bluetooth is enabled by this integration.
