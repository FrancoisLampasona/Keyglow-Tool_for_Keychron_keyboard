// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main struct FirstInstallTests {
    static func le(_ n:UInt32)->Data {Data((0..<4).map{UInt8(truncatingIfNeeded:n >> (8*$0))})}
    static func reject(_ body:()->Void) {body()}
    static func rejects(_ body:()throws->Void) {do{try body();fatalError("Expected rejection")}catch{}}
    static let snapshot=VIASnapshot(layers:Array(repeating:Array(repeating:4,count:120),count:4),encoders:Array(repeating:[234,233],count:4),macroBuffer:Array(repeating:0,count:128),macroCount:4,macroCapacity:128,lighting:.init(brightness:120,effect:2,speed:127,hue:85,saturation:220),firmwareVersion:"original",protocolVersion:12,productID:0x0861)
    final class MemoryDFU:FirstInstallDFU {
        var flash:Data
        var writes:[UInt32]=[]
        var mismatchSecond=false,corruptStage=false,failLoader=false,wrongDevice=false
        var fullReads=0
        init(_ flash:Data){self.flash=flash}
        func identify(location:UInt32,serial:String?)throws->InstallUSBIdentity {
            guard !wrongDevice,location == 123,serial == nil || serial == "TEST" else{throw FirstInstallError("wrong unit")}
            return .init(location:123,serial:"TEST")
        }
        func read(address:UInt32,length:Int)throws->Data {
            let start=Int(address-0x08000000)
            if length == 262144 {fullReads+=1}
            var result=Data(flash[start..<start+length])
            if mismatchSecond && fullReads == 2 {result[100] ^= 1}
            if corruptStage && address == 0x08020000 {result[256] ^= 1}
            return result
        }
        func write(address:UInt32,bytes:Data)throws {
            writes.append(address)
            let start=Int(address-0x08000000),size=address == 0x08000000 ? 16384:131072
            flash.replaceSubrange(start..<start+size,with:Data(repeating:0xff,count:size))
            if address == 0x08000000 && failLoader {
                flash.replaceSubrange(0..<32,with:bytes.prefix(32));throw FirstInstallError("power interruption")
            }
            flash.replaceSubrange(start..<start+bytes.count,with:bytes)
        }
    }
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var flash=Data(repeating:0xff,count:262144)
        let standard=Data((0..<65536).map{UInt8(truncatingIfNeeded:$0*17)})
        flash.replaceSubrange(0..<standard.count,with:standard)
        var image=Data(repeating:42,count:1057);image.replaceSubrange(0..<8,with:le(0x20010000)+le(0x08008009))
        var loader=Data(repeating:51,count:128);loader.replaceSubrange(0..<8,with:le(0x20010000)+le(0x08000009))
        let artifact=try FirmwareUpdateArtifact.parse(image,fileName:"fixture.bin",isPackage:false,rawBuild:9)
        var header=Data("KGFW0001".utf8)+le(0x08613434)+le(0x08008000)+le(UInt32(image.count))+le(9)+FirmwareDeltaPlan.sha256(image)
        header.append(le(BluetoothOTAWire.crc32(Array(header))))
        let package=header+image
        let catalog=BootstrapCatalog(schema:1,target:0x08613434,loaderSHA256:bootstrapHash(loader),packageSHA256:bootstrapHash(package),usbVersion:"test-9",sources:[.init(name:"public-test-source",length:standard.count,vectorsSHA256:bootstrapHash(Data(standard.prefix(480))),codeSHA256:bootstrapHash(Data(standard[32768...])))])
        let key=try FirmwareOwnerKey(rawRepresentation:Data(1...32)) // Public deterministic fixture only.
        func fresh(_ name:String)throws->(FirstInstallStore,MemoryDFU,FirstInstallCoordinator) {
            let store=try FirstInstallStore(directory:root.appendingPathComponent(name))
            try store.save(.init(location:123,snapshot:snapshot))
            let dfu=MemoryDFU(flash)
            return (store,dfu,FirstInstallCoordinator(store:store,dfu:dfu))
        }
        func prepare(_ c:FirstInstallCoordinator)throws->FirstInstallJournal {try c.prepare(catalog:catalog,loader:loader,package:package,key:key)}
        func install(_ c:FirstInstallCoordinator,_ j:FirstInstallJournal)throws->FirstInstallJournal {try c.install(approvedStaging:j.hashes["staging.bin"]!,approvedLoader:j.hashes["loader-private.bin"]!)}
        let (store,dfu,coordinator)=try fresh("success")
        let prepared=try prepare(coordinator)
        precondition(dfu.writes.isEmpty && dfu.fullReads == 2 && prepared.phase == .prepared)
        let installed=try install(coordinator,prepared)
        precondition(installed.phase == .awaitingRestart && dfu.writes == [0x08020000,0x08000000])
        precondition(dfu.flash[0x4000..<0x20000] == flash[0x4000..<0x20000])
        let backup = try store.read("controller-original.bin");precondition(backup == flash)
        rejects{_ = try install(coordinator,installed)}
        let (_,badBackup,c1)=try fresh("different-read");badBackup.mismatchSecond=true
        rejects{_ = try prepare(c1)};precondition(badBackup.writes.isEmpty)
        let (_,wrong,c2)=try fresh("wrong-device");wrong.wrongDevice=true
        rejects{_ = try prepare(c2)};precondition(wrong.fullReads == 0 && wrong.writes.isEmpty)
        let (_,unknown,c3)=try fresh("unsupported");unknown.flash[400] ^= 1
        rejects{_ = try prepare(c3)};precondition(unknown.writes.isEmpty)
        let (_,moved,c4)=try fresh("changed-eeprom");let p4=try prepare(c4);moved.flash[0x4000] ^= 1
        rejects{_ = try install(c4,p4)};precondition(moved.writes.isEmpty)
        let (_,stageFailure,c5)=try fresh("stage-corrupt");let p5=try prepare(c5);stageFailure.corruptStage=true
        rejects{_ = try install(c5,p5)};precondition(stageFailure.writes == [0x08020000])
        stageFailure.corruptStage=false;_ = try install(c5,p5)
        precondition(stageFailure.writes == [0x08020000,0x08020000,0x08000000])
        let (resumeStore,partial,c6)=try fresh("partial-loader");let p6=try prepare(c6);partial.failLoader=true
        rejects{_ = try install(c6,p6)};let resumeJournal=try resumeStore.load();precondition(resumeJournal.phase == .loader)
        // New coordinator models app restart. Exact durable stage is reused.
        partial.failLoader=false;partial.corruptStage=true
        do {_ = try install(c6,p6);fatalError("Expected stage rejection after loader attempt")}
        catch {precondition(error.localizedDescription.contains("potrebbe essere incompleto"))}
        precondition(partial.writes == [0x08020000,0x08000000]);partial.corruptStage=false
        let resumed=FirstInstallCoordinator(store:try FirstInstallStore(directory:resumeStore.directory),dfu:partial)
        _ = try install(resumed,p6);precondition(partial.writes == [0x08020000,0x08000000,0x08000000])
        let (tamperStore,tamper,c7)=try fresh("tamper");let p7=try prepare(c7)
        try tamperStore.write(Data(repeating:0,count:16192),name:"loader-private.bin")
        rejects{_ = try install(c7,p7)};precondition(tamper.writes.isEmpty)
        let (_,changedApproval,c8)=try fresh("approval");let p8=try prepare(c8)
        rejects{_ = try c8.install(approvedStaging:"different",approvedLoader:p8.hashes["loader-private.bin"]!)}
        precondition(changedApproval.writes.isEmpty)
        var current=snapshot;current.firmwareVersion="test-9";current.layers[0][0]=99;current.lighting.effect=1
        let desired=try FirstInstallCoordinator.restoredSettings(saved:snapshot,current:current)
        precondition(desired.layers == snapshot.layers && desired.lighting == snapshot.lighting && desired.firmwareVersion == "test-9")
        current.macroCapacity=256;rejects{_ = try FirstInstallCoordinator.restoredSettings(saved:snapshot,current:current)}
        var opaque=snapshot;opaque.macroBuffer[0]=255
        current=snapshot;let restoredOpaque=try FirstInstallCoordinator.restoredSettings(saved:opaque,current:current);precondition(restoredOpaque.macroBuffer == opaque.macroBuffer)
        let generated=try BootstrapAssembler.make(target:artifact,loader:loader,source:Data(standard[32768...]),key:key,nonce:Data(repeating:7,count:16))
        // Python's existing assembler independently checks byte-for-byte parity.
        for (name,data) in [("fixture-image.bin",image),("fixture-loader.bin",loader),("fixture-source.bin",Data(standard[32768...])),("fixture-keyslot.bin",FirmwareAuthorization.bootstrapKeySlot(ownerKey:key)),("swift-stage.bin",generated.staging),("swift-loader.bin",generated.loader)] {try data.write(to:root.appendingPathComponent(name))}
        let src=try FirmwareAuthorization.InstalledImage(length:UInt32(standard.count-32768),sha256:FirmwareDeltaPlan.sha256(Data(standard[32768...])))
        try FirmwareAuthorization.makePayload(manifest:artifact.manifest,source:src,reportedCurrentImage:src,nonce:Data(repeating:7,count:16),replace:false,ownerKey:key).write(to:root.appendingPathComponent("fixture-auth.bin"))
        print("First install: backup, device binding, unchanged source, staging verification, partial-loader resume, exact approval, tamper rejection, restore migration passed (memory only).")
    }
}
