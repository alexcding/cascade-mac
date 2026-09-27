import Foundation

/// The composition boundary for creation flows. Views never resolve services or
/// construct models; a coordinator requests one model for each presentation.
@MainActor protocol CreationFlowFactory {
    func projectEditor(project: Project?, service: any ProjectService) -> ProjectEditorViewModel
}

@MainActor struct NativeCreationFlowFactory: CreationFlowFactory {
    var chooseFolder: () async -> String? = NativeFolderPicker.choose
    var chooseFile: (String) async -> String? = NativeFolderPicker.chooseFile(in:)

    func projectEditor(project: Project?, service: any ProjectService) -> ProjectEditorViewModel {
        ProjectEditorViewModel(project: project, service: service, chooseFolder: chooseFolder, chooseFile: chooseFile)
    }
}
