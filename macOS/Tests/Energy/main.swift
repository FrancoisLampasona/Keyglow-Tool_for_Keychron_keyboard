import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
var workspace = KeyboardWorkspace()
let savedLights = workspace.advanced.backlightSeconds
workspace.advanced.sleepMinutes = EnergyPolicy.reactiveMinutes
try workspace.validate()
check(workspace.advanced.sleepMinutes * 60 == 65520, "Reactive preset must fit UInt16 and the firmware contract")
check(workspace.advanced.backlightSeconds == savedLights, "Radio preset must preserve light timeout")
let export = try JSONEncoder().encode(workspace)
let restored = try JSONDecoder().decode(KeyboardWorkspace.self, from: export)
check(restored.advanced.sleepMinutes == 1092, "Energy preset must survive profile round-trip")
for invalid in [0, 1093, 65535] {
    workspace.advanced.sleepMinutes = invalid
    do { try workspace.validate(); fatalError("Accepted unsupported timeout \(invalid)") } catch {}
}
let manifest = FirmwareBuildInfo(buildTimestamp: "2026-10-26-21:38:21", capabilities: ["reactive-idle-65520"])
check(manifest.matches("v1.1.1 2026-10-26-21:38:21"), "Actual Keychron version format")
check(!manifest.matches("v1.1.1 2026-10-26-21:07:37"), "Older RGB-only build is not reactive firmware")
check(!manifest.matches("v1.1.0 2026-10-26-21:38:21"), "Different version must not be recognized")
check(!manifest.matches("test v1.1.1 2026-10-26-21:38:21"), "Substring matches are not valid build identity")
check(!manifest.supportsDirectRGB("v1.1.1 2026-10-26-21:38:21"), "Reactive-only firmware must not enable direct persistent RGB")
let directBuild = FirmwareBuildInfo(buildTimestamp: "2026-10-26-23:00:00", capabilities: ["rgb-ble-v3-direct", "rgb-ble-persistent"])
check(directBuild.supportsDirectRGB("v1.1.1 2026-10-26-23:00:00"), "Exact direct firmware match")
check(!directBuild.supportsDirectRGB("v1.1.1 2026-10-26-21:48:49"), "Installed 0.5 build must remain legacy")
let missingSave = FirmwareBuildInfo(buildTimestamp: "2026-10-26-23:00:00", capabilities: ["rgb-ble-v3-direct"])
check(!missingSave.supportsDirectRGB("v1.1.1 2026-10-26-23:00:00"), "Both direct and persistence capabilities required")
check(EnergyPolicy.duration(minutes: 1092) == "18 h 12 min", "Must not label finite radio timeout as never")
print("PASS: reactive timeout range, profile persistence, separate light timer and exact firmware-build recognition.")
