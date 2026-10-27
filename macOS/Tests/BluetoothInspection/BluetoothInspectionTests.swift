// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreBluetooth

@MainActor final class FakeBatteryReader: BatteryStatusReading {
    var isRunning=false
    var onFinish: ((BluetoothFirmwareInspection?, String, Bool) -> Void)?
    var starts=0
    var cancellations=0
    func start(batteryOnly: Bool) { precondition(batteryOnly); isRunning=true; starts+=1 }
    func cancel() {
        guard isRunning else { return }
        isRunning=false; cancellations+=1; onFinish?(nil,"cancelled",true)
    }
    func complete(_ percent: Int?, at date: Date) {
        precondition(isRunning); isRunning=false
        onFinish?(BluetoothFirmwareInspection(model:"Keychron Q6 Max",radioFirmware:nil,batteryPercent:percent,
            inspectedAt:date,serviceIDs:[],characteristics:[],vendorServicePresent:false),"test result",false)
    }
}

@main
struct BluetoothInspectionTests {
    @MainActor static func main() {
        let observed = Data([0x02, 0x34, 0x34, 0x61, 0x08, 0x01, 0x02])
        let identity = BluetoothQ6Identity.parse(observed)!
        precondition(identity.vendor == 0x3434 && identity.product == 0x0861 && identity.version == 0x0201)
        precondition(identity.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max"))
        precondition(identity.matches(name: " KEYCHRON Q6 MAX ", model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6", model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max Pro"))
        precondition(!identity.matches(name: nil, model: "Keychron Q6 Max"))
        precondition(!identity.matches(name: "Keychron Q6 Max", model: nil))
        for field in [1, 2, 3, 4] {
            var wrong = observed; wrong[field] ^= 1
            precondition(!BluetoothQ6Identity.parse(wrong)!.matches(name: "Keychron Q6 Max", model: "Keychron Q6 Max"))
        }
        for source: UInt8 in [0, 1, 3, 255] {
            var wrong = observed; wrong[0] = source
            precondition(BluetoothQ6Identity.parse(wrong) == nil)
        }
        precondition(BluetoothQ6Identity.parse(observed.dropLast()) == nil)
        precondition(BluetoothQ6Identity.parse(observed + Data([0])) == nil)
        precondition(BluetoothQ6Identity.parse(Data()) == nil)
        precondition(BluetoothQ6Identity.text(Data("0.2.1".utf8)) == "0.2.1")
        precondition(BluetoothQ6Identity.text(Data("Keychron Q6 Max\0".utf8)) == "Keychron Q6 Max")
        precondition(BluetoothQ6Identity.text(Data("Keychron\0Q6 Max".utf8)) == nil)
        precondition(BluetoothQ6Identity.text(Data([0xff, 0xfe])) == nil)
        precondition(BluetoothQ6Identity.text(Data(repeating: 65, count: 65)) == nil)
        precondition(BluetoothQ6Identity.text(Data()) == nil)
        for valid: UInt8 in [0, 84, 100] { precondition(BluetoothQ6Identity.battery(Data([valid])) == Int(valid)) }
        for invalid in [Data(), Data([101]), Data([255]), Data([84, 0])] { precondition(BluetoothQ6Identity.battery(invalid) == nil) }
        let now = Date(timeIntervalSince1970: 1000)
        let reading = BatteryReading(percent: 20, date: now)
        precondition(reading.isLow && reading.isFresh(at: now))
        precondition(!reading.isFresh(at: now.addingTimeInterval(181)))
        precondition(!reading.isFresh(at: now.addingTimeInterval(-1)))
        precondition(!BatteryReading(percent: 21, date: now).isLow)
        for connected in [false, true] { for sleeping in [false, true] { for paused in [false, true] {
            let context = BatteryRefreshContext(connected: connected, paused: paused, sleeping: sleeping)
            precondition(context.shouldRefreshConnection == (!sleeping && !paused))
            let allowed = connected && !sleeping && !paused
            precondition(context.shouldRefresh(authorized: true, running: false, lastAttempt: nil, now: now) == allowed)
            precondition(!context.shouldRefresh(authorized: false, running: false, lastAttempt: nil, now: now))
            precondition(!context.shouldRefresh(authorized: true, running: true, lastAttempt: nil, now: now))
            precondition(!context.shouldRefresh(authorized: true, running: false, lastAttempt: now.addingTimeInterval(-59), now: now))
            precondition(context.shouldRefresh(authorized: true, running: false, lastAttempt: now.addingTimeInterval(-60), now: now) == allowed)
        } } }
        monitorLifecycle()
        print("Bluetooth identity, battery parsing, freshness, app-owned monitoring, reconnect, permissions, busy/sleep cancellation and restart checks passed; no hardware connection created")
    }

    @MainActor static func monitorLifecycle() {
        let reader=FakeBatteryReader()
        var time=Date(timeIntervalSince1970:1000)
        var permission=CBManagerAuthorization.notDetermined
        var device=BatteryRefreshContext(connected:true,paused:false,deviceID:1)
        var discoveries=0
        let monitor=KeyboardStatusMonitor(reader:reader,clock:{time},permission:{permission})
        monitor.configure(snapshot:{device},refreshConnection:{discoveries+=1})
        monitor.start(); monitor.start()
        precondition(discoveries == 1 && reader.starts == 0) // Never prompts automatically.
        monitor.refresh(); precondition(reader.isRunning) // Only explicit action may request consent.
        time+=10; monitor.tick(); precondition(reader.isRunning && reader.cancellations == 0)
        reader.cancel(); reader.starts=0; reader.cancellations=0
        permission = .allowedAlways
        monitor.tick(); precondition(reader.starts == 1)
        reader.complete(90,at:time)
        time+=59; monitor.tick(); precondition(reader.starts == 1)
        time+=1; monitor.tick(); precondition(reader.starts == 2)
        reader.complete(90,at:time)
        precondition(monitor.reading?.date == time) // Same level still gets a new timestamp.
        time+=60; monitor.tick(); precondition(reader.isRunning)
        device.paused=true; monitor.reconcile()
        precondition(!reader.isRunning && reader.cancellations == 1 && !monitor.failed)
        precondition(monitor.reading?.percent == 90)
        let pausedDiscoveries=discoveries
        time+=100; monitor.tick(); precondition(discoveries == pausedDiscoveries)
        device.paused=false; monitor.tick(); precondition(reader.isRunning)
        reader.complete(89,at:time)
        device.connected=false; device.deviceID=nil; device.usbConnected=true
        monitor.tick(); precondition(monitor.reading == nil)
        let cableStarts=reader.starts
        time+=65; monitor.tick(); precondition(reader.starts == cableStarts)
        device.connected=true; device.deviceID=2; device.usbConnected=false
        monitor.tick(); precondition(reader.starts == cableStarts+1)
        reader.complete(88,at:time)
        device.deviceID=3; monitor.tick()
        precondition(monitor.reading == nil && reader.isRunning) // Do not reuse another device's reading.
        monitor.setSleeping(true)
        precondition(!reader.isRunning && !monitor.failed)
        let sleepingDiscoveries=discoveries
        time+=3600; monitor.tick(); precondition(discoveries == sleepingDiscoveries)
        monitor.setSleeping(false); precondition(reader.isRunning)
        reader.complete(nil,at:time); precondition(monitor.failed)
        let failedStarts=reader.starts
        time+=59; monitor.tick(); precondition(reader.starts == failedStarts)
        time+=1; monitor.tick(); precondition(reader.isRunning)
        permission = .denied; monitor.tick()
        precondition(!reader.isRunning && !monitor.failed)
        let deniedStarts=reader.starts
        time+=100; monitor.tick(); monitor.refresh(); precondition(reader.starts == deniedStarts)
        permission = .allowedAlways; monitor.tick(); precondition(reader.isRunning)
        monitor.stop(); precondition(!reader.isRunning)
        let stoppedDiscoveries=discoveries
        time+=100; monitor.tick(); precondition(discoveries == stoppedDiscoveries)
        monitor.start(); precondition(reader.isRunning)
        reader.complete(87,at:time); precondition(monitor.reading?.percent == 87)
        monitor.stop()
    }
}
