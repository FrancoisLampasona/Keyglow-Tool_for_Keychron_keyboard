import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func expectFailure(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure: \(message)") } catch {}
}

/// Independent protocol fixture, following the pinned firmware's byte offsets.
final class FirmwareFixture: VIAExchange {
    var keyBytes = Array(repeating:UInt8(0),count:960)
    var encoders = Array(repeating:[UInt16(0xEA),UInt16(0xE9)],count:4)
    var macros = Array(repeating:UInt8(0),count:128)
    var lighting = VIALighting(brightness:200,effect:1,speed:127,hue:85,saturation:220)
    var savedLighting = VIALighting(brightness:200,effect:1,speed:127,hue:85,saturation:220)
    var rgbMask:UInt8=0
    var writes = [[UInt8]]()
    var enableCustom = false
    var custom: VIACustomRGB = {
        let colors = Array(repeating: VIAHSV(hue: 0, saturation: 255, value: 200), count: 109)
        var indices = [[UInt8]]()
        for row in 0..<6 {
            var line = [UInt8]()
            for col in 0..<20 { let index = row * 20 + col; line.append(index < 109 ? UInt8(index) : 255) }
            indices.append(line)
        }
        let effect = VIAMixedEffect(effect: 0, hue: 0, saturation: 255, speed: 127, durationMilliseconds: 5000)
        let effects = Array(repeating: Array(repeating: effect, count: 4), count: 2)
        return VIACustomRGB(type: 0, colors: colors, ledIndices: indices, regions: Array(repeating: 0, count: 109), effects: effects, supportedIndicatorsMask: 3, indicatorsDisabledMask: 0, indicatorColor: VIAHSV(hue: 0, saturation: 0, value: 255))
    }()
    var wireless = VIAWirelessSettings(backlightTimeoutSeconds:30,sleepTimeoutSeconds:600)
    var nkro=false
    var resetColorOnEffect=false
    var ignoreKeyWrites=false
    var failMacroData=false
    var protocolVersion:UInt16=12

    func exchange(_ request:[UInt8])throws->[UInt8] {
        require(request.count==32,"Every request is32 bytes")
        var r=request
        func set16(_ n:UInt16,_ at:Int) { r[at]=UInt8(n>>8);r[at+1]=UInt8(n&255) }
        func little16(_ n:UInt16,_ at:Int) { r[at]=UInt8(n&255);r[at+1]=UInt8(n>>8) }
        let cmd=request[0]
        switch cmd {
        case 1:set16(protocolVersion,1)
        case 0x11:r[1]=4
        case 0x12:
            let offset=Int(request[1])*256+Int(request[2]),n=Int(request[3]);r.replaceSubrange(4..<(4+n),with:keyBytes[offset..<(offset+n)])
        case 0x05:
            writes.append(request)
            if !ignoreKeyWrites { let p=(Int(request[1])*120+Int(request[2])*20+Int(request[3]))*2;keyBytes[p]=request[4];keyBytes[p+1]=request[5] }
        case 0x14:set16(encoders[Int(request[1])][Int(request[3])],4)
        case 0x15:writes.append(request);encoders[Int(request[1])][Int(request[3])]=UInt16(request[4])*256+UInt16(request[5])
        case 0x0C:r[1]=4
        case 0x0D:set16(128,1)
        case 0x0E:
            let offset=Int(request[1])*256+Int(request[2]),n=Int(request[3]);r.replaceSubrange(4..<(4+n),with:macros[offset..<(offset+n)])
        case 0x0F:
            writes.append(request)
            let offset=Int(request[1])*256+Int(request[2]),n=Int(request[3])
            if failMacroData && offset==0 { throw VIAError.timeout(0x0F) }
            macros.replaceSubrange(offset..<(offset+n),with:request[4..<(4+n)])
        case 0x08:
            switch request[2] {case 1:r[3]=lighting.brightness;case 2:r[3]=lighting.effect;case 3:r[3]=lighting.speed;case 4:r[3]=lighting.hue;r[4]=lighting.saturation;default:fatalError("Unknown property")}
        case 0x07:
            writes.append(request);rgbMask |= 1<<request[2]
            switch request[2] {case 1:lighting.brightness=request[3];case 2:lighting.effect=request[3];if resetColorOnEffect {lighting.hue=0;lighting.saturation=255};case 3:lighting.speed=request[3];case 4:lighting.hue=request[3];lighting.saturation=request[4];default:fatalError("Unknown property")}
        case 0x09:
            writes.append(request)
            switch rgbMask {case 2:savedLighting.brightness=lighting.brightness;case 4:savedLighting.effect=lighting.effect;case 8:savedLighting.speed=lighting.speed;case 16:savedLighting.hue=lighting.hue;savedLighting.saturation=lighting.saturation;default:break};rgbMask=0
        case 0xA1:for (i,b) in "v1.2.3 test".utf8.enumerated(){r[i+1]=b}
        case 0xA2:r[1]=0;r[2]=enableCustom ? 0x87:7;r[3]=2
        case 0xA7:
            r[2]=0
            switch request[1] {
            case 1:r[3]=2;r[4]=0;r[5]=enableCustom ? 0x90:0
            case 0x0B:little16(wireless.backlightTimeoutSeconds,3);little16(wireless.sleepTimeoutSeconds,5)
            case 0x0C:writes.append(request);wireless.backlightTimeoutSeconds=UInt16(request[2])+UInt16(request[3])*256;wireless.sleepTimeoutSeconds=UInt16(request[4])+UInt16(request[5])*256
            case 0x12:r[3]=(nkro ? 1:0)|2
            case 0x13:writes.append(request);nkro=request[2] != 0
            default:r[0]=255
            }
        case 0xA8:
            r[2]=0
            let start=Int(request[2]),n=Int(request[3])
            switch request[1] {
            case 1:r[3]=1;r[4]=0
            case 2:writes.append(request)
            case 3:r[3]=3;r[4]=custom.indicatorsDisabledMask;r[5]=custom.indicatorColor.hue;r[6]=custom.indicatorColor.saturation;r[7]=custom.indicatorColor.value
            case 4:writes.append(request);custom.indicatorsDisabledMask=request[2];custom.indicatorColor=VIAHSV(hue:request[3],saturation:request[4],value:request[5])
            case 5:r[3]=109
            case 6:r.replaceSubrange(3..<23,with:custom.ledIndices[start])
            case 7:r[3]=custom.type
            case 8:writes.append(request);custom.type=request[2]
            case 9:for i in 0..<n {let c=custom.colors[start+i];r[3+i*3]=c.hue;r[4+i*3]=c.saturation;r[5+i*3]=c.value}
            case 10:writes.append(request);for i in 0..<n {custom.colors[start+i]=VIAHSV(hue:request[4+i*3],saturation:request[5+i*3],value:request[6+i*3])}
            case 11:r[3]=2;r[4]=4
            case 12:r.replaceSubrange(3..<(3+n),with:custom.regions[start..<(start+n)])
            case 13:writes.append(request);custom.regions.replaceSubrange(start..<(start+n),with:request[4..<(4+n)])
            case 14:
                let region=Int(request[2]),offset=Int(request[3]),count=Int(request[4])
                for i in 0..<count {let e=custom.effects[region][offset+i],p=3+i*8;r[p]=e.effect;r[p+1]=e.hue;r[p+2]=e.saturation;r[p+3]=e.speed;for byte in 0..<4 {r[p+4+byte]=UInt8((e.durationMilliseconds>>(8*byte))&255)}}
            case 15:
                writes.append(request)
                let region=Int(request[2]),offset=Int(request[3]),count=Int(request[4])
                for i in 0..<count {let p=5+i*8;var duration:UInt32=0;for byte in 0..<4 {duration|=UInt32(request[p+4+byte])<<(8*byte)};custom.effects[region][offset+i]=VIAMixedEffect(effect:request[p],hue:request[p+1],saturation:request[p+2],speed:request[p+3],durationMilliseconds:duration)}
            default:r[0]=255
            }
        default:r[0]=255
        }
        return r
    }
}

let actions:[[VIAMacroAction]]=[[.text("Hi"),.down(0xE0),.tap(6),.up(0xE0),.delay(1234),.text("!")],[],[.tap(40)]]
let encoded=try VIAMacroCodec.encode(actions,count:4,capacity:128)
require(Array(encoded.prefix(19)) == [72,105,1,2,224,1,1,6,1,3,224,1,4,49,50,51,52,124,33],"Macro golden bytes match QMK prefix, ASCII delay and terminator")
let decoded = try VIAMacroCodec.decode(encoded,count:4)
require(decoded == actions+[[]],"Macro roundtrip")
expectFailure("No UTF8 corruption") { _=try VIAMacroCodec.encode([[.text("è")]],count:4,capacity:128) }
expectFailure("Truncated macro") { _=try VIAMacroCodec.decode([1,1,0],count:1) }
expectFailure("Macro overflow") { _=try VIAMacroCodec.encode([[.text(String(repeating:"a",count:130))]],count:4,capacity:128) }
let rawDescriptor: [UInt8]=[0x06,0x60,0xFF,0x09,0x61,0xA1,0x01,0x09,0x62,0x15,0,0x26,0xFF,0,0x75,8,0x95,32,0x81,2,0x09,0x63,0x91,2,0xC0]
require(VIAUSBTransport.hasExpectedRawReport(Data(rawDescriptor)),"Expected raw HID descriptor")
require(!VIAUSBTransport.hasExpectedRawReport(Data([0x85,1]+rawDescriptor)),"Reject numbered report")
require(!VIAUSBTransport.hasExpectedRawReport(Data(rawDescriptor.dropLast(3))),"Reject truncated descriptor")

let fixture=FirmwareFixture(),client=VIAClient(exchange:fixture,productID:0x0861)
let base=try client.readSnapshot()
require(base.layers.count==4 && base.layers[0].count==120 && base.encoders[0]==[0xEA,0xE9],"Complete snapshot geometry and encoder order")
require(fixture.writes.isEmpty,"Snapshot is settings-read-only")
_=try client.applyChanges(baseline:base,desired:base)
require(fixture.writes.isEmpty,"No-change commit sends no setters")
var desired=base
desired.layers[2][93]=0x5C12;desired.encoders[1][0]=0x04;desired.macroBuffer=encoded
desired.lighting=VIALighting(brightness:170,effect:2,speed:90,hue:132,saturation:190)
let applied=try client.applyChanges(baseline:base,desired:desired)
require(applied.layers==desired.layers && applied.macroBuffer==encoded && applied.lighting==desired.lighting,"Delta commit readback")
require(fixture.savedLighting==desired.lighting,"One-property SAVE avoids firmware bitmask persistence bug")
let macroWrites=fixture.writes.filter{$0[0]==0x0F}
require(macroWrites.first?[1...4] == [0,127,1,255] && macroWrites.last?[1...4] == [0,127,1,0],"Macro playback guarded until final verified byte")

fixture.writes=[]
fixture.keyBytes[0]=7
expectFailure("Conflicting external edit") { _=try client.applyChanges(baseline:applied,desired:applied) }
require(fixture.writes.isEmpty,"Conflict fails before any setter")
var invalid=applied;invalid.layers[0].removeLast()
expectFailure("Invalid shape") { _=try client.applyChanges(baseline:applied,desired:invalid) }
require(fixture.writes.isEmpty,"Malformed draft fails before any setter")

let ignored=FirmwareFixture(),ignoredClient=VIAClient(exchange:ignored,productID:0x0861)
let ignoredBase=try ignoredClient.readSnapshot();var ignoredDraft=ignoredBase;ignoredDraft.layers[0][0]=8;ignored.ignoreKeyWrites=true
expectFailure("Firmware ignores write: readback must fail") { _=try ignoredClient.applyChanges(baseline:ignoredBase,desired:ignoredDraft) }
let interrupted=FirmwareFixture(),interruptedClient=VIAClient(exchange:interrupted,productID:0x0861)
let interruptedBase=try interruptedClient.readSnapshot();var interruptedDraft=interruptedBase;interruptedDraft.macroBuffer=encoded;interrupted.failMacroData=true
expectFailure("Interrupted macro upload") { _=try interruptedClient.applyChanges(baseline:interruptedBase,desired:interruptedDraft) }
require(interrupted.macros.last==255,"Interrupted macro upload remains safely playback-disabled")

let customFixture=FirmwareFixture();customFixture.enableCustom=true
let customClient=VIAClient(exchange:customFixture,productID:0x0861),customBase=try customClient.readSnapshot()
require(customBase.customRGB?.colors.count==109 && customBase.customRGB?.ledIndices[5][19]==255,"Custom RGB capability and matrix mapping")
var customDraft=customBase
customDraft.customRGB!.colors[108]=VIAHSV(hue:42,saturation:83,value:190)
customDraft.customRGB!.type=3
customDraft.customRGB!.regions[108]=1
customDraft.customRGB!.effects[1][3]=VIAMixedEffect(effect:5,hue:30,saturation:230,speed:190,durationMilliseconds:123456)
customDraft.customRGB!.indicatorsDisabledMask=1
customDraft.wireless=VIAWirelessSettings(backlightTimeoutSeconds:300,sleepTimeoutSeconds:900)
customDraft.nkro=true
let customApplied=try customClient.applyChanges(baseline:customBase,desired:customDraft)
require(customApplied.customRGB==customDraft.customRGB && customApplied.wireless==customDraft.wireless && customApplied.nkro==true,"Custom RGB/mix, LE duration/timeouts, NKRO verified readback")
require(customFixture.writes.allSatisfy{$0.count==32},"All custom writes bounded to32 bytes")
print("VIA: macro golden format, malformed inputs, descriptor guards, complete read-only snapshot, delta/readback, RGB persistence, conflict, ignored writes, interrupted macros, per-key/mix and advanced settings passed. No hardware access.")

let effectFixture=FirmwareFixture(),effectClient=VIAClient(exchange:effectFixture,productID:0x0861)
let effectBase=try effectClient.readSnapshot();var effectDraft=effectBase;effectDraft.lighting.effect=2;effectFixture.resetColorOnEffect=true
let effectResult=try effectClient.applyChanges(baseline:effectBase,desired:effectDraft)
require(effectResult.lighting.hue == effectBase.lighting.hue && effectResult.lighting.saturation == effectBase.lighting.saturation,"Restore resends color after an effect transition resets firmware color")
let opaqueFixture=FirmwareFixture(),opaqueClient=VIAClient(exchange:opaqueFixture,productID:0x0861)
let opaqueBase=try opaqueClient.readSnapshot();var opaqueDraft=opaqueBase;opaqueDraft.macroBuffer[0]=1;opaqueDraft.macroBuffer[1]=99
expectFailure("Normal editor cannot introduce unsupported raw macro commands") {_ = try opaqueClient.applyChanges(baseline:opaqueBase,desired:opaqueDraft)}
require(opaqueFixture.writes.isEmpty,"Opaque editor rejection precedes writes")
let opaqueResult=try opaqueClient.applyChanges(baseline:opaqueBase,desired:opaqueDraft,allowOpaqueMacroRestore:true)
require(opaqueResult.macroBuffer == opaqueDraft.macroBuffer,"Explicit original-backup restore preserves opaque macro bytes")
print("First-install VIA restoration: original opaque macros and effect/color transition verified.")
