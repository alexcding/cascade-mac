import Foundation

@MainActor protocol PageActionServing {
    func openPage(_ request: OpenPageRequest) async throws
    func copyLink(_ value: String)
}

@MainActor struct NativePageActionService: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void
    let copy: (String) -> Void

    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
    func copyLink(_ value: String) { copy(value) }
}
