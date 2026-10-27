// SPDX-License-Identifier: GPL-2.0-or-later
// Isolated visual fixture. No bundle resources, device sessions or owner keys.
import AppKit
import SwiftUI

@MainActor final class PreviewDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:640),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Keyglow · Anteprima di test (nessun dispositivo)";window.minSize=NSSize(width:900,height:640)
        window.contentView=NSHostingView(rootView:PreviewRoot())
        let menu=NSMenu(),item=NSMenuItem();menu.addItem(item);let app=NSMenu();item.submenu=app
        app.addItem(withTitle:"Esci",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");NSApp.mainMenu=menu
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
@MainActor struct PreviewPermissions:OnboardingPermissionServicing {
    func checkAccess()->OnboardingPermissionState{.granted}
    func requestAccess()->Bool{false}
    func openSettings()->Bool{false}
}
struct PreviewRoot:View {
    @State private var index=0
    let models:[FirstInstallModel]
    let onboarding:OnboardingModel
    let setup:KeyboardSetupModel
    init() {
        let defaults=UserDefaults(suiteName:"keyglow.visual-fixture.volatile")!
        onboarding=OnboardingModel(permissions:PreviewPermissions(),defaults:defaults)
        setup=KeyboardSetupModel(defaults:defaults,inventory:{[.init(id:1,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"USB")]});setup.step=3;setup.firmwareChoice = .install
        let snapshot=VIASnapshot(layers:Array(repeating:Array(repeating:4,count:120),count:4),encoders:Array(repeating:[234,233],count:4),macroBuffer:Array(repeating:0,count:128),macroCount:4,macroCapacity:128,lighting:.init(brightness:100,effect:2,speed:127,hue:85,saturation:200),firmwareVersion:"public fixture",protocolVersion:12,productID:0x0861)
        func journal(_ phase:FirstInstallJournal.Phase)->FirstInstallJournal {
            var j=FirstInstallJournal(location:123,snapshot:snapshot);j.phase=phase;j.targetBuild=9;j.sourceName="Q6 Max ISO v1.1.0 · dati di test";j.hashes=["owner-keyslot.bin":String(repeating:"ef",count:32),"staging.bin":String(repeating:"ab",count:32),"loader-private.bin":String(repeating:"cd",count:32)];return j
        }
        var withoutKey=journal(.profileSaved);withoutKey.hashes.removeValue(forKey:"owner-keyslot.bin")
        models=[.init(previewJournal:nil),.init(previewJournal:journal(.profileSaved)),.init(previewJournal:journal(.prepared)),.init(previewJournal:journal(.loader),busy:true),.init(previewJournal:journal(.awaitingRestart)),.init(previewJournal:journal(.complete)),.init(previewJournal:journal(.staging),error:true),.init(previewJournal:withoutKey),.init(previewJournal:journal(.loader),error:true),.init(previewJournal:nil,unreadable:true)]
    }
    var body:some View {
        HStack(spacing:0) {
        Text("Anteprima\nQ6 Max ISO").frame(width:180).frame(maxHeight:.infinity).background(Studio.rail)
        VStack(spacing:0) {
            Text("Firmware").font(.system(size:28,weight:.semibold)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,28).padding(.top,28)
            Picker("Anteprima",selection:$index) {
                ForEach(Array(["Backup","DFU","Riepilogo","Scrittura","Ripristino","Completato","Errore","Chiave","Errore loader","Sessione illeggibile","Riepilogo iniziale"].enumerated()),id:\.offset){i,title in Text(title).tag(i)}
            }.pickerStyle(.menu).padding(16)
            if index == 10 {OnboardingView(model:onboarding,setup:setup,onContinue:{},onLater:{})} else {
            ScrollViewReader {proxy in
                ScrollView {StudioSurface {FirstInstallView(model:models[index],onBluetooth:{})}.studioPage().id("top")}
                    .onChange(of:index){_ in proxy.scrollTo("top",anchor:.top)}
            }}
        }
        }.background(Studio.background).foregroundColor(Studio.text).tint(Studio.accent).environment(\.studioContentWidth,660)
    }
}
@main struct PreviewEntry {
    @MainActor static func main() {let delegate=PreviewDelegate();NSApplication.shared.delegate=delegate;NSApplication.shared.setActivationPolicy(.regular);NSApplication.shared.run();_ = delegate}
}
