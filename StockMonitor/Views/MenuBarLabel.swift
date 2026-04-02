import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            if appState.statusBarSegments.isEmpty {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                let seg = appState.statusBarSegments[appState.statusBarCurrentIndex]
                Text(seg.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(segColor(seg))
            }
            if appState.hasError {
                Text(" ⚠").font(.system(size: 11)).foregroundColor(.yellow)
            }
        }
    }

    private func segColor(_ seg: AppState.StatusBarSegment) -> Color {
        if seg.isSecondary { return .secondary }
        if seg.isUp        { return Color(appState.config.upColorName) }
        if seg.isDown      { return Color(appState.config.downColorName) }
        return .primary
    }
}
