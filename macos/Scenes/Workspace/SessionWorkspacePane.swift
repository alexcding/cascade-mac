import SwiftUI

/// A session's context pane, beside its terminal: the window's inspector column
/// (`MainSplitViewController`), whose tab bar sits in the pane's own section of the toolbar
/// (`SessionWorkspaceToolbar`). The bar's field is up there, but its suggestions hang here, at the
/// top of the pane, from the editing state the bar keeps on the models.
struct SessionWorkspacePane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        SessionWorkspaceContextBody(context: context, model: model)
            .overlay(alignment: .top) {
                Group {
                    if model.showsBrowser {
                        BrowserAddressSuggestionList(context: context, model: model)
                    } else if model.showsFiles {
                        FileSearchResultList(context: context, model: model)
                    }
                }
                .padding(.top, 4).padding(.horizontal, 8)
            }
    }
}
