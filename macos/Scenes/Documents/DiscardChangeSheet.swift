import SwiftUI

struct DiscardChangeSheet: View {
    let model: GitChangesActions
    let proposal: DiscardProposal
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discard this change block?").font(.title2.weight(.semibold))
            Text(proposal.path).font(.headline).textSelection(.enabled)
            Text("This rewrites the selected block on disk and cannot be undone. Other change blocks remain.")
            ScrollView([.horizontal, .vertical]) {
                Text(proposal.patch).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(height: 240).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel, action: model.cancelDiscard).keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Discard Block", role: .destructive) { Task { await model.confirmDiscard() } }.disabled(model.busy)
            }
        }.padding(24).frame(width: 620)
        .interactiveDismissDisabled(model.busy)
    }
}
