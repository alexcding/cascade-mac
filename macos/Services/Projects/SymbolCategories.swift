import Foundation

/// The SF Symbols app's categories, read from the tables macOS keeps beside its symbols
/// (CoreGlyphs), each with the symbols it holds in the system's own order. Empty when the
/// tables cannot be read, and the picker then shows every symbol with no categories.
struct SymbolCategories: Sendable {
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let icon: String
        /// nil for All, which the picker lists itself.
        let symbols: [String]?

        var title: String {
            switch id {
            case "all": String(localized: "All")
            case "whatsnew": String(localized: "What's New")
            case "draw": String(localized: "Draw")
            case "variable": String(localized: "Variable")
            case "multicolor": String(localized: "Multicolor")
            case "communication": String(localized: "Communication")
            case "weather": String(localized: "Weather")
            case "maps": String(localized: "Maps")
            case "objectsandtools": String(localized: "Objects & Tools")
            case "devices": String(localized: "Devices")
            case "cameraandphotos": String(localized: "Camera & Photos")
            case "gaming": String(localized: "Gaming")
            case "connectivity": String(localized: "Connectivity")
            case "transportation": String(localized: "Transportation")
            case "automotive": String(localized: "Automotive")
            case "accessibility": String(localized: "Accessibility")
            case "privacyandsecurity": String(localized: "Privacy & Security")
            case "human": String(localized: "Human")
            case "home": String(localized: "Home")
            case "fitness": String(localized: "Fitness")
            case "nature": String(localized: "Nature")
            case "editing": String(localized: "Editing")
            case "textformatting": String(localized: "Text Formatting")
            case "media": String(localized: "Media")
            case "keyboard": String(localized: "Keyboard")
            case "commerce": String(localized: "Commerce")
            case "time": String(localized: "Time")
            case "health": String(localized: "Health")
            case "shapes": String(localized: "Shapes")
            case "arrows": String(localized: "Arrows")
            case "indices": String(localized: "Indices")
            case "math": String(localized: "Math")
            default: id.capitalized
            }
        }
    }

    let categories: [Category]

    static let system = SymbolCategories(
        resources: URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"))

    /// Reads `categories.plist`, `symbol_categories.plist` and `symbol_order.plist` from `resources`.
    init(resources: URL) {
        func plist<T>(_ name: String, as: T.Type) -> T? {
            (try? Data(contentsOf: resources.appendingPathComponent(name)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? T }
        }
        guard let listed = plist("categories.plist", as: [[String: Any]].self),
              let membership = plist("symbol_categories.plist", as: [String: [String]].self) else {
            categories = []
            return
        }
        let order = plist("symbol_order.plist", as: [String].self) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [String: [String]] = [:]
        for (symbol, keys) in membership { for key in keys { members[key, default: []].append(symbol) } }
        categories = listed.compactMap { entry in
            guard let key = entry["key"] as? String else { return nil }
            let icon = entry["icon"] as? String ?? "square.grid.2x2"
            if key == "all" { return Category(id: key, icon: icon, symbols: nil) }
            guard let symbols = members[key], !symbols.isEmpty else { return nil }
            return Category(id: key, icon: icon, symbols: symbols.sorted {
                (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1)
            })
        }
    }
}
