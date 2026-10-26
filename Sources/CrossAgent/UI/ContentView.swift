import SwiftUI

struct ContentView: View {
    @StateObject private var pane = PaneSession(host: HostStore.load()[0], mode: .shell, session: "ca-mac-1")

    var body: some View {
        TerminalHost(terminal: pane.terminal)
            .padding(6)
            .background(Color(nsColor: Theme.window))
            .onAppear { pane.start() }
    }
}
