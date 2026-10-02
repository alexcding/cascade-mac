import SwiftUI

struct DiffView: View {
    @Bindable var model: DiffViewModel
    var title = String(localized: "Changes")
    /// The session workspace draws these controls in its review bar instead.
    var showsHeader = true
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header; Divider() }
            if let error = model.error {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); Spacer(); Button(String(localized: "Reload Changes"), action: model.reload) }.padding(10)
                Divider()
            }
            if let view = model.webView { BrowserSurface(webView: view) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .sheet(item: Binding(get: { model.coordinator.discardProposal }, set: { if $0 == nil { model.coordinator.dismissDiscard() } })) { proposal in
            if let actions = model.actions { DiscardChangeSheet(model: actions, proposal: proposal) }
        }
    }

    private var header: some View {
        HStack {
            Label(title, systemImage: "arrow.triangle.branch").font(.headline).lineLimit(1)
            if let branch = model.snapshot?.branch { Text(branch).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if model.actions != nil {
                Button(String(localized: "Commit…"), systemImage: "checkmark.circle", action: model.requestActions).disabled(model.actions?.busy == true)
                    .commitPopover(model)
            }
            if model.showsProgress { ProgressView().controlSize(.small) }
        }.padding(10)
    }
}

extension View {
    /// Commit and Push opens beside the button that asked for it rather than as a sheet over the pane.
    func commitPopover(_ diff: DiffViewModel) -> some View {
        popover(isPresented: Binding(get: { diff.coordinator.showsActions }, set: { if !$0 { diff.coordinator.actionsClosed() } }),
                arrowEdge: .top) {
            if let actions = diff.actions { GitChangesSheet(model: actions) }
        }
    }
}
