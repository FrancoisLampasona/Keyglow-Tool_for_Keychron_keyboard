import AppKit

/// Local NSEvents only: no global input monitor, no background key capture.
@MainActor extension StudioModel {
    func startMappingCapture() { guard !selectedKeys.isEmpty else { return }; stopCapture(); captureMapping=true; installLocalCapture() }
    func startTest() { stopCapture(); testing=true; installLocalCapture() }
    func startRecording() {
        guard workspace.macros.indices.contains(selectedMacro), workspace.macros[selectedMacro].rawBytes == nil else { return }
        stopCapture(); recording=true; lastRecordedAt=nil; recordingPressed=[]; installLocalCapture()
    }
    func stopCapture() {
        if recording, workspace.macros.indices.contains(selectedMacro) {
            for code in recordingPressed.sorted() { workspace.macros[selectedMacro].actions.append(MacroActionDraft(kind:.up,keycode:UInt16(code))) }
        }
        if let monitor=localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor=nil }
        recording=false; testing=false; captureMapping=false; pressedKeys=[]; recordingPressed=[]; lastRecordedAt=nil
    }
    private func installLocalCapture() {
        localEventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, NSApp.isActive, (self.recording && self.section == 2) || (self.testing && self.section == 3) || (self.captureMapping && self.section == 1) else { return false }
                if event.keyCode == 53, event.type == .keyDown { self.stopCapture(); return true }
                guard let usage=MacPhysicalCodes.hid[event.keyCode] else { return false }
                if self.captureMapping {
                    guard event.type == .keyDown else { return true }
                    var modifiers: UInt16 = 0
                    if event.modifierFlags.contains(.control) { modifiers |= 1 }
                    if event.modifierFlags.contains(.shift) { modifiers |= 2 }
                    if event.modifierFlags.contains(.option) { modifiers |= 4 }
                    if event.modifierFlags.contains(.command) { modifiers |= 8 }
                    self.assignKeycode((modifiers << 8) | UInt16(usage)); self.stopCapture(); return true
                }
                let down:Bool
                if event.type == .flagsChanged { down = MacPhysicalCodes.flag(for:event.keyCode).map { event.modifierFlags.contains($0) } ?? false }
                else { down = event.type == .keyDown }
                if event.isARepeat { return true }
                if self.testing {
                    let match=self.definition.keys.first { self.definition.defaultLayers[0][$0.matrixIndex] == UInt16(usage) || self.definition.defaultLayers[2][$0.matrixIndex] == UInt16(usage) }
                    if let key=match {
                        if down { self.pressedKeys.insert(key.id); self.testedKeys.insert(key.id) } else { self.pressedKeys.remove(key.id) }
                        self.lastTestKey="\(key.legend.isEmpty ? KeycodeCatalog.display(UInt16(usage)) : key.legend) · \(down ? "premuto" : "rilasciato")"
                    } else { self.lastTestKey="\(KeycodeCatalog.display(UInt16(usage))) · ricevuto dal sistema" }
                }
                if self.recording {
                    guard self.workspace.macros.indices.contains(self.selectedMacro) else { self.stopCapture();return true }
                    let now=event.timestamp
                    if let previous=self.lastRecordedAt { let delay=Int((now-previous)*1000); if delay>15 { self.workspace.macros[self.selectedMacro].actions.append(MacroActionDraft(kind:.delay,milliseconds:min(65535,delay))) } }
                    if down { self.recordingPressed.insert(usage) } else { self.recordingPressed.remove(usage) }
                    self.workspace.macros[self.selectedMacro].actions.append(MacroActionDraft(kind:down ? .down : .up,keycode:UInt16(usage)))
                    self.lastRecordedAt=now
                }
                return true
            }
            return consumed ? nil : event
        }
    }
}
private enum MacPhysicalCodes {
    static let hid:[UInt16:UInt8]=[
        0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,10:100,11:5,12:20,13:26,14:8,15:21,16:28,17:23,
        18:30,19:31,20:32,21:33,22:35,23:34,24:46,25:38,26:36,27:45,28:37,29:39,30:48,31:18,32:24,33:47,34:12,35:19,
        36:40,37:15,38:13,39:52,40:14,41:51,42:50,43:54,44:56,45:17,46:16,47:55,48:43,49:44,50:53,51:42,53:41,
        54:231,55:227,56:225,57:57,58:226,59:224,60:229,61:230,62:228,
        64:108,65:99,67:85,69:87,71:83,75:84,76:88,78:86,79:109,80:110,81:103,82:98,83:89,84:90,85:91,86:92,87:93,88:94,89:95,91:96,92:97,
        96:62,97:63,98:64,99:60,100:65,101:66,103:68,105:104,106:107,107:105,109:67,111:69,113:106,114:73,115:74,116:75,117:76,118:61,119:77,120:59,121:78,122:58,123:80,124:79,125:81,126:82
    ]
    static func flag(for code:UInt16)->NSEvent.ModifierFlags? {
        switch code { case 54,55: .command; case 56,60: .shift; case 58,61: .option; case 59,62: .control; case 57: .capsLock; default:nil }
    }
}
