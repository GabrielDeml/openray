import Foundation
import Testing

import OpenRayCore

@Suite struct IdentifierTests {
    private let uuid = UUID(uuidString: "6F1C2D3E-0000-4000-8000-00000000ABCD")!

    @Test func eachNamespaceHasItsDocumentedFormat() {
        #expect(ItemID.app(bundleID: "com.apple.Safari").rawValue == "app:com.apple.Safari")
        #expect(
            ItemID.app(path: "/Applications/Old/Safari.app").rawValue
                == "app:path:/Applications/Old/Safari.app")
        #expect(ItemID.system("sleep").rawValue == "system:sleep")
        #expect(
            ItemID.command(FeatureID(rawValue: "clipboard"), "history").rawValue
                == "command:clipboard.history")
        #expect(
            ItemID.quicklink(uuid).rawValue == "quicklink:6F1C2D3E-0000-4000-8000-00000000ABCD")
        #expect(ItemID.script(path: "/Users/me/wifi.sh").rawValue == "script:/Users/me/wifi.sh")
        #expect(ItemID.file(path: "/Users/me/report.pdf").rawValue == "file:/Users/me/report.pdf")
        #expect(ItemID.clip(rowID: 4182).rawValue == "clip:4182")
        #expect(ItemID.snippet(uuid).rawValue == "snippet:6F1C2D3E-0000-4000-8000-00000000ABCD")
    }

    @Test func namespaceAndLocalPartSplitAtTheFirstColon() {
        let id = ItemID(rawValue: "app:path:/Applications/A:B.app")
        #expect(id.namespace == .app)
        #expect(id.local == "path:/Applications/A:B.app")
    }

    @Test func unknownNamespaceIsNil() {
        #expect(ItemID(rawValue: "widget:1").namespace == nil)
        #expect(ItemID(rawValue: "no-colon").namespace == nil)
        #expect(ItemID(rawValue: "no-colon").local == "")
    }

    @Test func identifiersAreStoredAsPlainStrings() throws {
        let request = ScreenRequest(
            feature: FeatureID(rawValue: "ai"), screen: "chat", argument: "hello")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        #expect(
            json as? [String: String] == ["feature": "ai", "screen": "chat", "argument": "hello"])

        let ids = [ItemID.system("sleep"), ItemID.clip(rowID: 7)]
        let encoded = try JSONEncoder().encode(ids)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["system:sleep","clip:7"]"#)
        #expect(try JSONDecoder().decode([ItemID].self, from: encoded) == ids)

        let action = try JSONEncoder().encode([ActionID(rawValue: "open")])
        #expect(String(decoding: action, as: UTF8.self) == #"["open"]"#)
    }
}
