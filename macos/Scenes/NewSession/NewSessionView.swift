import SwiftUI

/// New Task: the picked project's Start, whose project chip switches between projects.
struct NewSessionView: View {
    let model: NewSessionViewModel

    var body: some View {
        if let project = model.project, let composer = model.composer {
            ProjectComposerView(project: project, model: composer, projects: model.projects, onChooseProject: model.choose,
                                onNewProject: model.newProject)
                // Each composer is its own view: a switch of project, or a composer rebuilt for the same
                // one on reconnect, takes the old one off screen and brings the new one on.
                .id(ObjectIdentifier(composer))
                .padding(28)
        } else if model.projects.isEmpty {
            // Nothing to start a task in yet: the way to make the first project is right here.
            ContentUnavailableView {
                Label(String(localized: "No Projects"), systemImage: "folder")
            } description: {
                Text("Add a project with a folder to start sessions in it.")
            } actions: {
                Button(String(localized: "New Project…"), action: model.newProject)
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("new-task-new-project")
            }
        } else {
            Text("Connect to start sessions.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
