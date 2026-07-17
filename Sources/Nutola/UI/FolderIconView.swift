import SwiftUI

extension MeetingFolder {
    var iconColor: Color { Color(hex: iconColorHex) ?? Theme.mint }
}

struct FolderIconView: View {
    @Environment(\.colorScheme) private var scheme
    let folder: MeetingFolder
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.card(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(folder.iconColor.opacity(0.35), lineWidth: 1))
            iconContent
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var iconContent: some View {
        switch folder.iconKind {
        case .symbol:
            Image(systemName: folder.iconValue)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(folder.iconColor)
        case .emoji:
            Text(folder.iconValue)
                .font(.system(size: size * 0.48))
        }
    }
}

struct FolderLabel: View {
    @Environment(\.colorScheme) private var scheme
    let folder: MeetingFolder
    var iconSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            FolderIconView(folder: folder, size: iconSize)
            Text(folder.name)
                .font(.nutola(13, .medium))
                .foregroundStyle(Theme.heading(scheme))
                .lineLimit(1)
        }
    }
}
