import Foundation

/// Workspace-owned inputs. Changing style updates the retained surface; changing
/// activation controls loading and suspension without depending on a mounted view.
struct DocumentPresentation: Equatable {
    var active = false
    var appearance = AppAppearance.system
    var font = CodeFont(size: 12)
    var editor = EditorStyle()
}
