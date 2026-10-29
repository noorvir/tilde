import AppKit
import SwiftUI
import WebKit

/// Tilde's browser window: a dark Tilde frame, like the preview card, around the page as an
/// inset rounded card, with the notes panel on the right and lines from notes to their
/// elements. The page is the only light thing in the window.
struct BrowserView: View {
    @ObservedObject var browser: BrowserController

    var body: some View {
        VStack(spacing: 0) {
            if let controller = browser.controller {
                BrowserToolbar(browser: browser, controller: controller)
            }
            HStack(spacing: BrowserMetrics.frame) {
                WebView(webView: browser.webView)
                    .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.pageRadius))
                    .overlay(RoundedRectangle(cornerRadius: BrowserMetrics.pageRadius).strokeBorder(Color.white.opacity(0.08)))
                    .anchorPreference(key: NoteGeometry.self, value: .bounds) { NoteGeometry.Value(page: $0) }
                if browser.showsNotes, let controller = browser.controller {
                    NotesPanel(controller: controller, browser: browser)
                        .frame(width: BrowserMetrics.panelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding([.horizontal, .bottom], BrowserMetrics.frame)
        }
        .background(Color(white: 0.1))
        .overlayPreferenceValue(NoteGeometry.self) { geometry in
            GeometryReader { proxy in
                ConnectorLines(browser: browser, geometry: geometry, proxy: proxy)
            }
            .allowsHitTesting(false)
        }
        .tildeTooltipHostAboveAppKit()
        .overlay(alignment: .topTrailing) {
            if let controller = browser.controller {
                EmbeddedPauseToast(controller: controller)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: browser.showsNotes)
        .ignoresSafeArea()
    }
}

/// The pause note under the toolbar's HUD, right-aligned with it, drawn above the page.
private struct EmbeddedPauseToast: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        if controller.isHUDInBrowser, let notice = controller.pauseNotice {
            AboveAppKit {
                PauseToast(notice: notice, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(width: HUDView.width, height: 72)
            .padding(.top, BrowserMetrics.toolbarHeight + 4)
            .padding(.trailing, BrowserMetrics.frame)
            .transition(.opacity)
        }
    }
}

/// Spacing of the browser window, from the preview card's tokens.
enum BrowserMetrics {
    /// The dark frame around the page and between the page and the panel.
    static let frame: CGFloat = 8
    static let pageRadius: CGFloat = 10
    static let panelWidth: CGFloat = 300
    static let toolbarHeight: CGFloat = 52
    static let addressMinWidth: CGFloat = 240
    /// Room for the traffic lights, the navigation buttons, the shortest address field and
    /// the HUD, so nothing in the toolbar is cut.
    static let minWindowWidth: CGFloat = 84 + 3 * (30 + 4) + 4 + addressMinWidth + 4 + 8 + HUDView.embeddedWidth + frame
}

/// The title-bar row in the HUD's dark style: back, forward, reload and the address field,
/// then the session's HUD while the browser hosts it, or else the Tilde mark and the notes
/// toggle.
struct BrowserToolbar: View {
    @ObservedObject var browser: BrowserController
    @ObservedObject var controller: AnnotationController
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 4) {
            button("chevron.left", help: "Back", enabled: browser.canGoBack) { browser.webView.goBack() }
            button("chevron.right", help: "Forward", enabled: browser.canGoForward) { browser.webView.goForward() }
            button(browser.isLoading ? "xmark" : "arrow.clockwise", help: browser.isLoading ? "Stop" : "Reload", enabled: true) {
                browser.reloadOrStop()
            }

            TextField("", text: $draft, prompt: Text("Search or enter website").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($editing)
                .onSubmit { browser.load(draft) }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                .frame(minWidth: BrowserMetrics.addressMinWidth, maxWidth: .infinity)
                .padding(.leading, 4)

            if controller.isHUDInBrowser {
                HUDView(controller: controller, isEmbedded: true)
                    .padding(.leading, 8)
            } else {
                Image(nsImage: TildeMark.menuBarImage())
                    .renderingMode(.template)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28)
                    .accessibilityLabel("Tilde")
                button("sidebar.right", help: browser.showsNotes ? "Hide notes" : "Show notes", enabled: true, isOn: browser.showsNotes) {
                    browser.showsNotes.toggle()
                }
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, controller.isHUDInBrowser ? BrowserMetrics.frame : BrowserMetrics.frame + 4)
        .frame(height: BrowserMetrics.toolbarHeight)
        .onAppear { draft = browser.address }
        .onChange(of: browser.addressFocusRequest) { _, _ in
            editing = true
            // Selects the whole address once the field has the keyboard, as in Safari.
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: browser.address) { _, address in
            if !editing {
                draft = address
            }
        }
    }

    private func button(_ symbol: String, help: String, enabled: Bool, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isOn ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
