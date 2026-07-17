import SwiftUI

struct FolderPickerMenu<MenuLabel: View>: View {
    @EnvironmentObject private var app: AppState
    var currentFolderID: UUID?
    var calendarTitle: String?
    var meetingID: UUID?
    @ViewBuilder var label: () -> MenuLabel

    @State private var showNewFolder = false

    var body: some View {
        Menu {
            ForEach(app.folders.folders) { folder in
                Button {
                    pick(folder: folder)
                } label: {
                    if folder.id == currentFolderID {
                        Label {
                            Text(folder.name)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Label {
                            Text(folder.name)
                        } icon: {
                            folderMenuIcon(folder)
                        }
                    }
                }
            }
            if !app.folders.folders.isEmpty {
                Divider()
            }
            Button("New folder…") { showNewFolder = true }
            if currentFolderID != nil, meetingID != nil {
                Divider()
                Button("Remove from folder") {
                    app.folders.assign(meetingID: meetingID!, to: nil, meetingStore: app.store)
                }
            }
        } label: {
            label()
        }
        .sheet(isPresented: $showNewFolder) {
            FolderEditorSheet(title: "New folder") { name, description, kind, value, colorHex in
                let folder = app.folders.createFolder(
                    name: name,
                    description: description,
                    iconKind: kind,
                    iconValue: value,
                    iconColorHex: colorHex)
                pick(folder: folder)
            }
        }
    }

    @ViewBuilder
    private func folderMenuIcon(_ folder: MeetingFolder) -> some View {
        switch folder.iconKind {
        case .symbol:
            Image(systemName: folder.iconValue)
                .foregroundStyle(folder.iconColor)
        case .emoji:
            Text(folder.iconValue)
        }
    }

    private func pick(folder: MeetingFolder) {
        if let meetingID {
            app.folders.assign(meetingID: meetingID, to: folder.id, meetingStore: app.store)
        } else if let calendarTitle {
            app.folders.assign(calendarTitle: calendarTitle, to: folder.id, meetingStore: app.store)
        }
    }
}
