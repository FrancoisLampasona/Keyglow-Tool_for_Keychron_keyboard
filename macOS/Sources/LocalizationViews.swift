// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine

@MainActor final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    static let didChange = Notification.Name("KeyglowLanguageChanged")
    @Published var language = AppLanguage.current {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}

struct LText: View {
    let source: String
    @ObservedObject private var language = AppLanguageStore.shared
    init(_ source: String) { self.source = source }
    var body: some View { Text(verbatim: L10n.catalog.text(source, language: language.language)) }
}

@MainActor func LLabel(_ title: String, systemImage: String) -> some View {
    Label { LText(title) } icon: { Image(systemName: systemImage) }
}
@MainActor func LButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) { LText(title) }
}
@MainActor func LToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) { LText(title) }
}
@MainActor func LMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    Menu(content: content) { LText(title) }
}
@MainActor func LPicker<Value: Hashable, Content: View>(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) -> some View {
    Picker(selection: selection, content: content) { LText(title) }
}
@MainActor func LDisclosureGroup<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    DisclosureGroup(content: content) { LText(title) }
}
@MainActor func LDisclosureGroup<Content: View>(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
    DisclosureGroup(isExpanded: isExpanded, content: content) { LText(title) }
}
@MainActor func LTextField(_ title: String, text: Binding<String>) -> some View {
    TextField(text: text) { LText(title) }
}
@MainActor func LTextField<Value, Format: ParseableFormatStyle>(_ title: String, value: Binding<Value>, format: Format) -> some View where Format.FormatInput == Value, Format.FormatOutput == String {
    TextField(value: value, format: format) { LText(title) }
}

private struct LocalizedHelp: ViewModifier {
    let source: String
    @ObservedObject private var language = AppLanguageStore.shared
    func body(content: Content) -> some View { content.help(Text(verbatim: L10n.catalog.text(source, language: language.language))) }
}
private struct LocalizedAccessibilityLabel: ViewModifier {
    let source: String
    @ObservedObject private var language = AppLanguageStore.shared
    func body(content: Content) -> some View { content.accessibilityLabel(Text(verbatim: L10n.catalog.text(source, language: language.language))) }
}
extension View {
    func localizedHelp(_ source: String) -> some View { modifier(LocalizedHelp(source: source)) }
    func localizedAccessibilityLabel(_ source: String) -> some View { modifier(LocalizedAccessibilityLabel(source: source)) }
}

struct LanguageMenu: View {
    @ObservedObject private var store = AppLanguageStore.shared
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button { store.language = language } label: {
                    Label(language.nativeName, systemImage: store.language == language ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(store.language.nativeName, systemImage: "globe").font(.system(size: 11, weight: .medium))
        }.menuStyle(.borderlessButton).fixedSize().localizedHelp("Lingua dell’interfaccia")
            .localizedAccessibilityLabel("Lingua dell’interfaccia")
    }
}
