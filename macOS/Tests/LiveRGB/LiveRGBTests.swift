import Foundation

@main @MainActor
struct LiveRGBTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, line: Int = #line) {
        checks += 1; if !condition() { fatalError("Live RGB assertion at \(line)") }
    }
    static func color(_ effect: Int, hue: Double = 0.3) -> LiveRGBColor {
        LiveRGBColor(effect: effect, hue: hue, saturation: 0.8, value: 0.9, brightness: 70, speed: 120)
    }
    static func start(_ state: inout LiveRGBCoordinator, save: Bool = true) {
        state.configure(enabled: true, allowed: true, save: save, now: 0)
    }
    static func main() throws {
        let a = color(1), b = color(2), c = color(3)
        var s = LiveRGBCoordinator()
        check(!s.enabled && s.nextDeadline == nil)
        s.edit(a, now: 0); check(s.takeReady(now: 10) == nil) // launch cannot send
        s.configure(enabled: true, allowed: false, save: true, now: 0)
        s.edit(a, now: 0); check(s.nextDeadline == nil)
        s.configure(enabled: true, allowed: true, save: true, now: 5)
        check(s.takeReady(now: 20) == nil) // discovery/permission alone cannot send
        s.edit(a, now: 20); check(s.takeReady(now: 20.39) == nil)
        let first = s.takeReady(now: 20.4)!; check(first.color == a && !first.save)
        let firstPacket = try first.color.packet(save: first.save); check(firstPacket[5] == 3)
        s.edit(b, now: 21); s.edit(c, now: 22)
        check(s.pending == c && s.takeReady(now: 100) == nil && s.active == first)
        s.complete(first, succeeded: true, now: 25)
        let latest = s.takeReady(now: 25)!; check(latest.color == c && !latest.save)
        check(s.takeReady(now: 100) == nil)
        s.complete(latest, succeeded: true, now: 30)
        check(s.waitingToSave && s.takeReady(now: 31.49) == nil)
        let saved = s.takeReady(now: 31.5)!; check(saved.save && saved.color == c)
        let savedPacket = try saved.color.packet(save: saved.save); check(savedPacket[5] == 4)
        s.complete(saved, succeeded: true, now: 36.5)
        check(s.nextDeadline == nil && s.active == nil)
        s.edit(c, now: 40); check(s.takeReady(now: 100) == nil) // unchanged value doesn't resend

        s = LiveRGBCoordinator(); start(&s, save: false)
        for i in 0..<100 {
            s.edit(color(1, hue: Double(i) / 100), now: Double(i) * 0.05)
            check(s.takeReady(now: Double(i) * 0.05 + 0.049) == nil)
        }
        check(s.takeReady(now: 5.349) == nil)
        let drag = s.takeReady(now: 5.351)!; check(drag.color == color(1, hue: 0.99) && !drag.save)
        s.complete(drag, succeeded: true, now: 11)
        check(s.nextDeadline == nil && s.takeReady(now: 100) == nil)

        // Returning to the already in-flight value removes an obsolete queued color.
        s = LiveRGBCoordinator(); start(&s)
        s.edit(a, now: 0); let inflight = s.takeReady(now: 1)!
        s.edit(b, now: 2); check(s.hasQueuedChange)
        s.edit(a, now: 3); check(!s.hasQueuedChange)
        s.complete(inflight, succeeded: true, now: 6)
        check(s.takeReady(now: 7.4) == nil && s.waitingToSave)
        s.edit(c, now: 7.4); check(!s.waitingToSave)
        let replacement = s.takeReady(now: 7.81)!; check(!replacement.save && replacement.color == c)

        // Opt-out cancels only unsent work and final save, never the active write.
        s.configure(enabled: false, allowed: true, save: true, now: 8)
        check(s.active == replacement && !s.hasQueuedChange && !s.waitingToSave)
        s.complete(replacement, succeeded: true, now: 13)
        check(s.nextDeadline == nil && s.takeReady(now: 100) == nil)
        s.configure(enabled: true, allowed: true, save: true, now: 20)
        check(s.nextDeadline == nil) // enabling context doesn't replay abandoned work

        for unavailable in 0..<4 { // USB/OTA busy, disconnected, access lost, unsupported effect
            s = LiveRGBCoordinator(); start(&s)
            s.edit(a, now: 0); let active = s.takeReady(now: 1)!
            s.edit(b, now: 2)
            s.configure(enabled: true, allowed: false, save: true, now: Double(unavailable + 3))
            check(!s.hasQueuedChange && s.active == active)
            s.complete(active, succeeded: true, now: 10)
            s.configure(enabled: true, allowed: true, save: true, now: 11)
            check(s.nextDeadline == nil && s.takeReady(now: 100) == nil)
        }
        s = LiveRGBCoordinator(); start(&s)
        s.edit(color(23), now: 0); check(s.nextDeadline == nil)
        s.edit(color(24), now: 0); check(s.nextDeadline == nil)
        s.edit(a, now: 1); let failed = s.takeReady(now: 2)!
        s.edit(b, now: 3); s.complete(failed, succeeded: false, now: 7)
        check(s.nextDeadline == nil && s.pending == nil)

        // Turning Save off while a temporary send runs cancels the later persistence.
        s = LiveRGBCoordinator(); start(&s)
        s.edit(a, now: 0); let temporary = s.takeReady(now: 1)!
        s.configure(enabled: true, allowed: true, save: false, now: 2)
        s.complete(temporary, succeeded: true, now: 6)
        check(s.takeReady(now: 100) == nil)
        s.configure(enabled: true, allowed: true, save: true, now: 7)
        check(s.takeReady(now: 8.49) == nil)
        let persistence = s.takeReady(now: 8.5)!; check(persistence.save)
        s.edit(b, now: 9); check(s.pending == b)
        s.configure(enabled: true, allowed: true, save: false, now: 10)
        check(s.active == persistence) // already submitted save cannot be retracted
        s.complete(persistence, succeeded: true, now: 14)
        let following = s.takeReady(now: 14)!; check(!following.save && following.color == b)
        s.complete(temporary, succeeded: true, now: 15); check(s.active == following) // stale completion ignored
        s.complete(following, succeeded: true, now: 19); check(s.nextDeadline == nil)

        // Every emitted packet retains the production RGB validation boundary.
        for effect in 0...22 {
            for save in [false, true] {
                let packet = try color(effect).packet(save: save)
                check(RGBProtocol.validMasks(RGBProtocol.masks(for: packet)))
                check(packet[4] == 3 && packet[5] == (save ? 4 : 3))
                if effect == 0 { check(packet[6...10].allSatisfy { $0 == 0 }) }
            }
        }
        let bounded = LiveRGBColor(effect: 1, hue: .nan, saturation: -.infinity, value: .infinity, brightness: 50, speed: 999)
        check(bounded.hue == 0 && bounded.saturation == 0 && bounded.value == 0 && bounded.speed == 255)
        print("Live RGB: \(checks) assertions passed; no device, timer or preference APIs invoked.")
    }
}
