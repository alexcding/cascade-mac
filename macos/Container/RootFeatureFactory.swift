import Foundation

@MainActor protocol RootFeatureFactory {
    func root(service: any RootServing, shell: ShellStore, viewer: ViewerStore) -> RootViewModel
}

@MainActor struct NativeRootFeatureFactory: RootFeatureFactory {
    func root(service: any RootServing, shell: ShellStore, viewer: ViewerStore) -> RootViewModel {
        RootViewModel(service: service, shell: shell, viewer: viewer)
    }
}
