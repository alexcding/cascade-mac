import Foundation

/// A new session always belongs to `project`, decided by where it was asked for.
struct SessionCreationRequest {
    let project: Project
    let agent: SessionAgent
    let pageURL: String?
}

/// The composition boundary for creation flows. Views never resolve services or
/// construct models; a coordinator requests one model for each presentation.
@MainActor protocol CreationFlowFactory {
    func projectEditor(project: Project?, service: any ProjectService) -> ProjectEditorViewModel
    func newSession(request: SessionCreationRequest, operations: (any SessionCreating)?) -> NewSessionViewModel
}

@MainActor struct NativeCreationFlowFactory: CreationFlowFactory {
    var chooseFolder: () async -> String? = NativeFolderPicker.choose
    var chooseFile: (String) async -> String? = NativeFolderPicker.chooseFile(in:)

    func projectEditor(project: Project?, service: any ProjectService) -> ProjectEditorViewModel {
        ProjectEditorViewModel(project: project, service: service, chooseFolder: chooseFolder, chooseFile: chooseFile)
    }

    func newSession(request: SessionCreationRequest, operations: (any SessionCreating)?) -> NewSessionViewModel {
        let model = NewSessionViewModel(project: request.project, contextURL: request.pageURL, operations: operations)
        model.draft.agent = request.agent
        if let url = request.pageURL, SessionPage.parse(url) != nil { model.input = url }
        return model
    }
}
