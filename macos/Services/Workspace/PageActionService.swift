import Foundation

@MainActor protocol PageActionServing {
    func openPage(_ request: OpenPageRequest) async throws
}

@MainActor struct NativePageActionService: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void

    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
}
