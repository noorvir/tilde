import AppKit
import SwiftUI
import TildeCore

extension CookieBrowser {
    /// The browsers with logins on this Mac that are still installed.
    static func installed() -> [CookieBrowser] {
        BrowserCookies.browsers().filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

/// A quiet bar over the page until logins are imported: Import opens the same chooser as
/// Settings › Browser. × hides it until Tilde quits; "Don't show again" for good.
struct LoginImportBar: View {
    static let enabledKey = "OfferLoginImport"
    @ObservedObject var browser: BrowserController
    @AppStorage("BrowserImport.summary") private var lastImport = ""
    @AppStorage(Self.enabledKey) private var isEnabled = true
    @State private var choice: [CookieBrowser]?

    var body: some View {
        if browser.pageURL != nil, lastImport.isEmpty, isEnabled, !browser.hidesLoginImport {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
                Text("Import logins from your browser so pages open signed in")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Import") {
                    choice = CookieBrowser.installed()
                }
                .controlSize(.small)
                Button("Don't show again") {
                    isEnabled = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .help("Settings › Browser still imports logins")
                Button {
                    browser.hidesLoginImport = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Hide until Tilde quits")
                .accessibilityLabel("Hide")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .environment(\.colorScheme, .dark)
            .padding([.horizontal, .bottom], BrowserMetrics.frame)
            .sheet(item: Binding(get: { choice.map(BrowserChoice.init) }, set: { choice = $0?.browsers })) { item in
                ImportSheet(browsers: item.browsers, browser: browser) { summary in
                    if let summary {
                        lastImport = summary
                    }
                    choice = nil
                }
            }
        }
    }
}
