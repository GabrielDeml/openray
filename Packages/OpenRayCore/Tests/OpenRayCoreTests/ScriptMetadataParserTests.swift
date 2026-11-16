import Foundation
import Testing

import OpenRayCore

/// The text of `Fixtures/scripts/<name>`. The files there are only ever read: none of them is
/// executable and no test runs one.
private func scriptFixture(_ name: String) throws -> String {
    let fileName = name as NSString
    let url = try #require(
        Bundle.module.url(
            forResource: fileName.deletingPathExtension, withExtension: fileName.pathExtension,
            subdirectory: "Fixtures/scripts"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// A header with the three required lines and the ones a test adds.
private func header(with lines: String...) -> String {
    var text =
        "#!/bin/sh\n# @openray.schemaVersion 1\n# @openray.title Test\n# @openray.mode silent\n"
    for line in lines {
        text += line + "\n"
    }
    return text
}

@Suite struct ScriptMetadataParserTests {
    // MARK: Golden files

    @Test func completeHeaderIsReadKeyByKey() throws {
        let metadata = try ScriptMetadataParser.parse(try scriptFixture("complete.sh")).get()

        let expected = ScriptMetadata(
            title: "Toggle Wi-Fi", mode: .silent, icon: .emoji("📶"),
            description: "Turns Wi-Fi on or off", keywords: ["wifi", "network", "airport"],
            arguments: [
                ScriptArgument(placeholder: "SSID", isOptional: true),
                ScriptArgument(placeholder: "Password", isOptional: false),
            ],
            timeout: .seconds(30), needsConfirmation: true)
        #expect(metadata == expected)
    }

    @Test func everyCommentPrefixIsAccepted() throws {
        let slashes = try ScriptMetadataParser.parse(try scriptFixture("slashes.js")).get()
        #expect(
            slashes
                == ScriptMetadata(
                    title: "Count Words", mode: .fullOutput, keywords: ["words", "count"]))

        let dashes = try ScriptMetadataParser.parse(try scriptFixture("dashes.lua")).get()
        #expect(dashes == ScriptMetadata(title: "Roll Dice", mode: .silent, icon: .symbol("dice")))

        let semicolons = try ScriptMetadataParser.parse(try scriptFixture("semicolons.scm")).get()
        #expect(
            semicolons
                == ScriptMetadata(title: "Greet", mode: .silent, description: "Says hello"))
    }

    @Test func windowsLineEndingsAreLineEndings() throws {
        let text = try scriptFixture("crlf.sh")
        // What the test is about; Git must leave the file's line endings alone.
        try #require(text.contains("\r\n"))

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(
            metadata
                == ScriptMetadata(
                    title: "Windows Line Endings", mode: .fullOutput, timeout: .seconds(120)))
    }

    @Test(arguments: [
        ("malformed-argument.sh", ScriptParseError.malformedArgument(1)),
        ("argument-not-an-object.sh", .malformedArgument(1)),
        ("dropdown-argument.sh", .invalidValue(key: "argument1")),
        ("argument-gap.sh", .argumentGap(2)),
        ("unknown-schema-version.sh", .unsupportedSchemaVersion("2")),
        ("missing-schema-version.sh", .missingKey("schemaVersion")),
        ("missing-title.sh", .missingKey("title")),
        ("missing-mode.sh", .missingKey("mode")),
        ("duplicate-key.sh", .duplicateKey("title")),
        ("no-metadata.sh", .noMetadata),
    ])
    func fileThatIsNoScript(fixture: String, error: ScriptParseError) throws {
        #expect(ScriptMetadataParser.parse(try scriptFixture(fixture)) == .failure(error))
    }

    @Test func unknownKeysAreSkippedAlsoWhenRepeated() throws {
        let metadata = try ScriptMetadataParser.parse(try scriptFixture("unknown-key.sh")).get()

        #expect(metadata == ScriptMetadata(title: "Unknown Key", mode: .silent))
    }

    // MARK: Lines

    @Test func byteOrderMarkBeforeTheFirstLineIsPassedOver() throws {
        // As an editor on Windows saves it: the mark, and CR LF at the line ends.
        let text =
            "\u{FEFF}# @openray.schemaVersion 1\r\n# @openray.title Toggle Wi-Fi\r\n"
            + "# @openray.mode silent\r\n"

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata.title == "Toggle Wi-Fi")
        // Only at the very beginning. Anywhere else it is a character like any other.
        #expect(
            ScriptMetadataParser.parse("echo\n\u{FEFF}# @openray.title T\n")
                == .failure(.noMetadata))
    }

    @Test func oldMacLineEndingsAreLineEndings() throws {
        let text =
            "#!/bin/sh\r# @openray.schemaVersion 1\r# @openray.title Old\r# @openray.mode silent"

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata == ScriptMetadata(title: "Old", mode: .silent))
    }

    @Test func valueIsTheRestOfTheLineWithoutTheSpaceAroundIt() throws {
        let text = header(with: "#\t@openray.description \t  Two  words  (and a remark) \t")

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata.description == "Two  words  (and a remark)")
    }

    @Test func lineWithCodeBeforeTheCommentIsNotMetadata() {
        let text = """
            #!/bin/sh
            echo hello # @openray.schemaVersion 1
            title="# @openray.title Test"
            ## @openray.mode silent
            #! @openray.mode silent
            """

        #expect(ScriptMetadataParser.parse(text) == .failure(.noMetadata))
    }

    @Test func keysAreExactInCase() {
        let text = "# @openray.schemaversion 1\n# @openray.title Test\n# @openray.mode silent\n"

        // The line counts as metadata, with a key nobody knows.
        #expect(ScriptMetadataParser.parse(text) == .failure(.missingKey("schemaVersion")))
    }

    @Test func emptyTextAndTextWithoutLinesHaveNoMetadata() {
        #expect(ScriptMetadataParser.parse("") == .failure(.noMetadata))
        #expect(ScriptMetadataParser.parse("\n\r\n\r") == .failure(.noMetadata))
        #expect(ScriptMetadataParser.parse("@openray.title Test") == .failure(.noMetadata))
    }

    // MARK: Values

    @Test func requiredKeyWithoutAValueCountsAsMissing() {
        let text = "# @openray.schemaVersion 1\n# @openray.title   \n# @openray.mode silent\n"

        #expect(ScriptMetadataParser.parse(text) == .failure(.missingKey("title")))
    }

    @Test(arguments: ["Silent", "full", "inline", ""])
    func modeHasToBeOneOfTheTwo(mode: String) {
        let text = "# @openray.schemaVersion 1\n# @openray.title Test\n# @openray.mode \(mode)\n"

        #expect(ScriptMetadataParser.parse(text) == .failure(.invalidValue(key: "mode")))
    }

    @Test(arguments: ["0", "2", "1.0", "one", ""])
    func schemaVersionHasToBeOne(version: String) {
        let text =
            "# @openray.schemaVersion \(version)\n# @openray.title Test\n# @openray.mode silent\n"

        #expect(
            ScriptMetadataParser.parse(text) == .failure(.unsupportedSchemaVersion(version)))
    }

    @Test(arguments: [
        ("📶", ScriptIcon.emoji("📶")),
        ("sf:wifi", .symbol("wifi")),
        ("sf:arrow.up.circle", .symbol("arrow.up.circle")),
        ("icons/wifi.png", .image(relativePath: "icons/wifi.png")),
        ("wifi.png", .image(relativePath: "wifi.png")),
    ])
    func iconForms(text: String, icon: ScriptIcon) throws {
        let metadata = try ScriptMetadataParser.parse(header(with: "# @openray.icon \(text)")).get()

        #expect(metadata.icon == icon)
    }

    @Test func iconDescriptionAndKeywordsWithoutAValueCountAsNotGiven() throws {
        let text = header(
            with: "# @openray.icon", "# @openray.description ", "# @openray.keywords")

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata == ScriptMetadata(title: "Test", mode: .silent))
    }

    @Test func argumentWithoutFieldsIsARequiredOneWithoutPlaceholder() throws {
        let text = header(with: "# @openray.argument1 {}")

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata.arguments == [ScriptArgument(placeholder: "", isOptional: false)])
    }

    @Test func threeArgumentsKeepTheirOrderWhateverTheOrderOfTheLines() throws {
        let text = header(
            with: "# @openray.argument3 {\"placeholder\":\"c\",\"type\":\"text\"}",
            "# @openray.argument1 {\"placeholder\":\"a\"}",
            "# @openray.argument2 {\"placeholder\":\"b\",\"optional\":true}")

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(
            metadata.arguments == [
                ScriptArgument(placeholder: "a", isOptional: false),
                ScriptArgument(placeholder: "b", isOptional: true),
                ScriptArgument(placeholder: "c", isOptional: false),
            ])
    }

    @Test(arguments: [
        "{\"placeholder\": 5}",
        "{\"optional\": \"yes\"}",
        "{\"optional\": 1}",
        "[{\"placeholder\": \"a\"}]",
        "",
    ])
    func argumentWithFieldsOfTheWrongKind(json: String) {
        let text = header(with: "# @openray.argument1 \(json)")

        #expect(ScriptMetadataParser.parse(text) == .failure(.malformedArgument(1)))
    }

    @Test func thirdArgumentWithoutTheSecond() {
        let text = header(with: "# @openray.argument1 {}", "# @openray.argument3 {}")

        #expect(ScriptMetadataParser.parse(text) == .failure(.argumentGap(3)))
    }

    @Test func fourthArgumentIsAKeyNobodyKnows() throws {
        let text = header(with: "# @openray.argument1 {}", "# @openray.argument4 {}")

        let metadata = try ScriptMetadataParser.parse(text).get()

        #expect(metadata.arguments.count == 1)
    }

    @Test func timeoutIsAWholeNumberOfSecondsUpToADay() throws {
        let shortest = try ScriptMetadataParser.parse(header(with: "# @openray.timeout 1")).get()
        #expect(shortest.timeout == .seconds(1))

        let longest = try ScriptMetadataParser.parse(header(with: "# @openray.timeout 86400"))
            .get()
        #expect(longest.timeout == .seconds(86_400))
    }

    @Test(arguments: ["0", "-5", "86401", "1.5", "30s", "soon", "", "99999999999999999999999"])
    func timeoutThatIsNoSuchNumber(value: String) {
        let text = header(with: "# @openray.timeout \(value)")

        #expect(ScriptMetadataParser.parse(text) == .failure(.invalidValue(key: "timeout")))
    }

    @Test func needsConfirmationIsTrueOrFalse() throws {
        let asked = try ScriptMetadataParser.parse(
            header(with: "# @openray.needsConfirmation true")
        ).get()
        #expect(asked.needsConfirmation)

        let notAsked = try ScriptMetadataParser.parse(
            header(with: "# @openray.needsConfirmation false")
        ).get()
        #expect(!notAsked.needsConfirmation)
    }

    @Test(arguments: ["yes", "1", "TRUE", ""])
    func needsConfirmationWithAnotherWord(value: String) {
        let text = header(with: "# @openray.needsConfirmation \(value)")

        #expect(
            ScriptMetadataParser.parse(text) == .failure(.invalidValue(key: "needsConfirmation")))
    }

    // MARK: Messages

    @Test func messagesNameTheKeyTheUserHasToFix() {
        #expect(ScriptParseError.missingKey("title").message == "@openray.title is missing.")
        #expect(
            ScriptParseError.malformedArgument(2).message
                == "@openray.argument2 is not valid JSON for an argument.")
        #expect(
            ScriptParseError.argumentGap(3).message
                == "@openray.argument3 is there, but @openray.argument2 is not.")
        #expect(
            ScriptParseError.duplicateKey("mode").message
                == "@openray.mode is there more than once.")
    }

    // MARK: Text nobody meant to be a script

    @Test(.timeLimit(.minutes(1))) func randomBytesNeverTrap() {
        var generator = SeededGenerator(seed: 8)
        // Bytes that make lines, comment prefixes and the marker turn up often.
        let likelyBytes = Array("\n\r #/-;@openray.{}\":1 \t".utf8)

        for _ in 0..<2_000 {
            var bytes: [UInt8] = []
            let length = Int.random(in: 0...300, using: &generator)
            for _ in 0..<length {
                if Bool.random(using: &generator) {
                    bytes.append(likelyBytes.randomElement(using: &generator) ?? 0)
                } else {
                    bytes.append(UInt8.random(in: 0...255, using: &generator))
                }
            }

            // Any answer will do. The test is that there is one.
            _ = ScriptMetadataParser.parse(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test(.timeLimit(.minutes(1))) func randomHeadersNeverTrap() {
        var generator = SeededGenerator(seed: 10)
        let keys = [
            "schemaVersion", "title", "mode", "icon", "keywords", "argument1", "argument2",
            "argument3", "timeout", "needsConfirmation", "", "argument", "argument0",
        ]
        let values = [
            "1", "silent", "fullOutput", "true", "{}", "{\"optional\":true}", "{", "[[[[", "",
            "-1", "\u{0}", "sf:", "/", "🙂", String(repeating: "[", count: 2_000),
        ]

        for _ in 0..<2_000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                let key = keys.randomElement(using: &generator) ?? ""
                let value = values.randomElement(using: &generator) ?? ""
                text += "# @openray.\(key) \(value)\n"
            }

            _ = ScriptMetadataParser.parse(text)
        }
    }

    @Test(.timeLimit(.minutes(1))) func longRunsOfTheMarkerEndQuickly() {
        let markers = String(repeating: "@openray.", count: 100_000)
        #expect(ScriptMetadataParser.parse(markers) == .failure(.noMetadata))

        // One long line that is metadata, with a key of nearly a megabyte.
        #expect(
            ScriptMetadataParser.parse("# " + markers) == .failure(.missingKey("schemaVersion")))

        let lines = String(repeating: "# @openray.\n", count: 100_000)
        #expect(ScriptMetadataParser.parse(lines) == .failure(.missingKey("schemaVersion")))

        let comments = String(repeating: "#", count: 500_000)
        #expect(ScriptMetadataParser.parse(comments) == .failure(.noMetadata))
    }
}
