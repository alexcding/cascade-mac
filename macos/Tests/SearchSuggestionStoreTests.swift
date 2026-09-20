import Foundation
import Testing
@testable import Craft

@MainActor @Test func searchSuggestionStoreParsesFirefoxAndChromeShapesAndCachesByQuery() async throws {
    let payload = #"["you",["youtube","youtube music","you"]]"#.data(using: .utf8)!
    #expect(SearchSuggestionStore.parse(payload) == ["youtube", "youtube music", "you"])
    let chrome = #"["githu",["github","https://github.com/","github login"],["","How people build software","" ],[],{"google:suggesttype":["QUERY","NAVIGATION","QUERY"]}]"#
    #expect(SearchSuggestionStore.parse(Data(chrome.utf8)) == ["github", SearchSuggestion(text: "https://github.com/", title: "How people build software", isSite: true), "github login"])
    #expect(SearchSuggestionStore.parse(Data("[]".utf8)).isEmpty)
    #expect(SearchSuggestionStore.parse(Data("nope".utf8)).isEmpty)

    var asked: [String] = []
    let store = SearchSuggestionStore { text in asked.append(text); return [SearchSuggestion(text: text + " music")] }
    #expect(store.cached(" You ").isEmpty) // Reading never fetches.
    store.prefetch(" You ")
    for _ in 0..<200 { if !store.results.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.cached("you") == ["you music"])
    store.prefetch("you"); try await Task.sleep(for: .milliseconds(200))
    #expect(asked == ["you"]) // One request for the normalised key, none for the cached repeat.
}
