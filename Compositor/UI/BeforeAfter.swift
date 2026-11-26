import AppKit
import SwiftUI

/// Over the canvas while an open panel's Preview is off (`EditorSession.toggleBeforeAfter`): says that what shows is
/// the layer as it was, with a way back to the edit.
struct BeforeBadge: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> CanvasPillView {
        CanvasPillView(symbol: "square.split.2x1", closeLabel: "Show the edit",
                       closeHelp: "Show the picture with the panel's changes again (\\)") { [session] in session.toggleBeforeAfter() }
    }
    func updateNSView(_ view: CanvasPillView, context: Context) {
        view.title = "Before"
        view.detail = "\\ shows After"
    }
}

/// Listens for the Before/After key for as long as the editor it sits behind shows.
struct BeforeAfterKeyListener: View {
    let session: EditorSession
    @State private var key = BeforeAfterKey()

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { key.session = session; key.listen() }
            .onChange(of: ObjectIdentifier(session)) { _, _ in key.session = session }
            .onDisappear { key.stopListening() }
    }
}

/// Before/After on its key (\, as in Lightroom) while a panel with a preview is open. It works wherever focus sits,
/// the panel or the document's window, except while typing text: a layer's name, the Type tool. An edit panel's
/// fields hold numbers, which the key has no part in, so one of those having the keyboard doesn't stop it.
final class BeforeAfterKey {
    weak var session: EditorSession?
    private var monitor: Any?

    func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] original in
            guard let session = self?.session, let event = ShortcutSettings.shared.canvasEvent(original),
                  event.charactersIgnoringModifiers == "\\", !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(event.window?.firstResponder is NSText) || FloatingPanelController.owns(event.window),
                  session.toggleBeforeAfter() else { return original }
            return nil
        }
    }
    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
