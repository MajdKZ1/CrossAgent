import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(app.panes) { pane in
                TerminalHost(terminal: pane.terminal)
            }
        }
        .padding(6)
        .background(Color(nsColor: Theme.window))
    }
}
