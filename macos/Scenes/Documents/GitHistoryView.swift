import SwiftUI

struct GitHistoryView: View {
    @Bindable var model: GitHistoryViewModel
    @FocusState private var finding: Bool
    @State private var showsMessage = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search loaded commits", text: $model.search).textFieldStyle(.roundedBorder).focused($finding)
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh History", systemImage: "arrow.clockwise", action: model.refresh).labelStyle(.iconOnly).disabled(model.loading)
            }.padding(10)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).padding(.horizontal, 10) }
            VSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.contextLabel).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                    List(selection: Binding(get: { model.selectedSHA }, set: model.select)) {
                        ForEach(model.rows) { commit in
                            HStack(spacing: 10) {
                                Text(commit.initials).font(.caption.bold()).frame(width: 30, height: 30)
                                    .background(.quaternary, in: Circle()).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(commit.subject).lineLimit(1).fontWeight(.medium)
                                    if !commit.refs.isEmpty {
                                        Text(commit.refs.map(\.name).joined(separator: " · ")).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                                    }
                                    Text("\(commit.author) · \(commit.dateLabel) · \(commit.short)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.tag(commit.sha).accessibilityIdentifier("history-commit-\(commit.sha)")
                        }
                    }.listStyle(.inset).accessibilityIdentifier("git-history-list")
                    if model.rows.isEmpty, !model.loading { Text(model.emptyLabel).foregroundStyle(.secondary).padding(10) }
                    if model.hasMore {
                        Button(model.loadingMore ? "Loading Older Commits…" : "Load Older Commits", action: model.loadMore)
                            .disabled(model.loading || model.loadingMore).padding(.horizontal, 10).padding(.bottom, 8)
                    }
                }.frame(minHeight: 130, idealHeight: 220)
                VStack(alignment: .leading, spacing: 0) {
                    // This region never changes size: selecting a commit swaps
                    // what is in it, and the previous commit stays up until the next one arrives.
                    if let error = model.detailError {
                        VStack(spacing: 8) {
                            Text(error).foregroundStyle(.orange)
                            Button("Retry Commit", action: model.retryDetail)
                        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let detail = model.detail {
                        // The diff is what this pane is for, so the commit takes two lines: the
                        // subject and who/when. A longer message opens on demand.
                        let hasBody = detail.meta.message != detail.meta.subject
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if hasBody {
                                    Button(showsMessage ? "Hide Commit Message" : "Show Commit Message",
                                           systemImage: showsMessage ? "chevron.down" : "chevron.right") { showsMessage.toggle() }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
                                }
                                Text(detail.meta.subject).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                if model.loadingDetail { ProgressView().controlSize(.small) }
                                Button("Copy Commit SHA", systemImage: "doc.on.doc", action: model.copySHA)
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                            Text(detail.meta.authorLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if hasBody, showsMessage {
                                ScrollView { Text(detail.meta.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 120).padding(.top, 4)
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 6).textSelection(.enabled)
                        Divider()
                        if let patch = model.patch { DiffView(model: patch, showsHeader: false) }
                    } else if model.loadingDetail {
                        ProgressView("Loading commit…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a commit", systemImage: "clock.arrow.circlepath")
                    }
                }.frame(minHeight: 160, maxHeight: .infinity)
            }
        }
        .onChange(of: model.findRequest) { _, _ in finding = true }
    }
}
