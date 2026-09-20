import SwiftUI

struct DiffView: View {
    @Bindable var model: DiffViewModel
    var title = "Changes"
    /// The session workspace draws these controls in its review footer instead.
    var showsHeader = true
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header; Divider() }
            if let error = model.error {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); Spacer(); Button("Reload Changes", action: model.reload) }.padding(10)
                Divider()
            }
            if let view = model.webView { BrowserSurface(webView: view) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .sheet(isPresented: Binding(get: { model.coordinator.showsActions }, set: { if !$0 { model.coordinator.dismissActions() } })) {
            if let actions = model.actions { GitChangesSheet(model: actions) }
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
                Button("Commit and Push…", systemImage: "arrow.up.circle", action: model.requestActions).disabled(model.actions?.busy == true)
            }
            if model.loading || model.actions?.busy == true { ProgressView().controlSize(.small) }
            Button("Refresh Changes", systemImage: "arrow.clockwise", action: model.refresh)
                .labelStyle(.iconOnly).disabled(model.loading || model.actions?.busy == true)
        }.padding(10)
    }
}
