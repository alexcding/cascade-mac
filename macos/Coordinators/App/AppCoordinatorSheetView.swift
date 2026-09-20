import SwiftUI

struct AppCoordinatorSheetView: View {
    let sheet: AppCoordinator.Sheet
    let cancel: () -> Void

    var body: some View {
        switch sheet.destination {
        case .newProject(let model): NewProjectSheet(model: model, cancel: cancel)
        case .newSession(let model): NewSessionView(model: model, cancel: cancel)
        case .build(let model): BuildDestinationView(model: model, cancel: cancel)
        case .welcome(let model): WelcomeView(model: model, cancel: cancel)
        }
    }
}
