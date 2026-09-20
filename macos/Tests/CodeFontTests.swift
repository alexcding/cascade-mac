import Foundation
import Testing

@Test func codeFontsValidateConfigurationAndKeepIndependentDefaults() throws {
    #expect(CodeFont(.term, settings: [:]).size == 13)
    #expect(CodeFont(.diff, settings: [:]).size == 12)
    #expect(CodeFont(.term, settings: ["term_font_size": "999"]).size == 20)
    #expect(CodeFont(.diff, settings: ["diff_font_size": "-1"]).size == 9)
    #expect(CodeFont(.term, settings: ["term_font_size": "invalid"]).size == 13)
    let saved = CodeFont(.term, settings: ["term_font_family": "Missing Custom Mono", "term_font_size": "17"])
    #expect(saved.family == "Missing Custom Mono" && saved.size == 17)
    for value in ["Menlo\nclipboard-write = deny", "Menlo\rcommand = injected", "null\0font", String(repeating: "x", count: 257)] {
        #expect(!CodeFont.validFamily(value))
        #expect(CodeFont(family: value, size: 13).family.isEmpty)
    }
    let font = CodeFont(family: "Quoted \" Mono \\ Face", size: 18)
    let json = try #require(JSONSerialization.jsonObject(with: Data(font.json.utf8)) as? [String: Any])
    #expect(json["family"] as? String == font.family)
    #expect(json["size"] as? Int == 18)
}

@Test func installedFontCatalogContainsLocalMonospaceFamilies() async {
    let families = await InstalledCodeFontCatalog().families()
    #expect(families.contains("Menlo"))
    #expect(!families.contains("Helvetica"))
    #expect(families.allSatisfy(CodeFont.validFamily))
}
