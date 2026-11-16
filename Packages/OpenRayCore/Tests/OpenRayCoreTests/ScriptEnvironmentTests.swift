import Foundation
import Testing

import OpenRayCore

@Suite struct ScriptEnvironmentTests {
    // MARK: What a script is given

    private func scriptVariables(base: [String: String]) -> [String: String] {
        ScriptEnvironment.variables(
            for: "/Users/me/Scripts/wifi.sh", base: base, appVersion: "0.3.0")
    }

    @Test func openRaysVariablesAreAddedToTheBase() {
        let variables = scriptVariables(base: ["HOME": "/Users/me", "LANG": "de_DE.UTF-8"])

        #expect(
            variables == [
                "HOME": "/Users/me",
                "LANG": "de_DE.UTF-8",
                "OPENRAY": "1",
                "OPENRAY_VERSION": "0.3.0",
                "OPENRAY_SCRIPT_PATH": "/Users/me/Scripts/wifi.sh",
                "NO_COLOR": "1",
                "TERM": "dumb",
            ])
    }

    @Test func openRaysVariablesWinOverTheBase() {
        let base = [
            "OPENRAY": "0", "OPENRAY_VERSION": "9", "OPENRAY_SCRIPT_PATH": "/other",
            "NO_COLOR": "", "TERM": "xterm-256color", "LANG": "C",
        ]

        let variables = scriptVariables(base: base)

        #expect(variables["OPENRAY"] == "1")
        #expect(variables["OPENRAY_VERSION"] == "0.3.0")
        #expect(variables["OPENRAY_SCRIPT_PATH"] == "/Users/me/Scripts/wifi.sh")
        #expect(variables["NO_COLOR"] == "1")
        #expect(variables["TERM"] == "dumb")
    }

    @Test func languageIsSetOnlyWhenThereIsNone() {
        #expect(scriptVariables(base: [:])["LANG"] == "en_US.UTF-8")
        #expect(scriptVariables(base: ["LANG": ""])["LANG"] == "en_US.UTF-8")
        #expect(scriptVariables(base: ["LANG": "C"])["LANG"] == "C")
        #expect(scriptVariables(base: ["LANG": "ja_JP.UTF-8"])["LANG"] == "ja_JP.UTF-8")
    }

    // MARK: Without the shell's environment

    @Test func fallbackPutsHomebrewInFrontOfThePath() {
        let fallback = ScriptEnvironment.fallback(
            inherited: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"])

        #expect(
            fallback == [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": "/Users/me",
            ])
    }

    @Test func fallbackWithoutAPathStartsFromTheSystems() {
        let expected = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        #expect(ScriptEnvironment.fallback(inherited: [:])["PATH"] == expected)
        #expect(ScriptEnvironment.fallback(inherited: ["PATH": ""])["PATH"] == expected)
    }

    @Test func fallbackDoesNotAddAFolderThePathAlreadyHas() {
        let withOne = ScriptEnvironment.fallback(
            inherited: ["PATH": "/usr/bin:/usr/local/bin:/bin"])
        #expect(withOne["PATH"] == "/opt/homebrew/bin:/usr/bin:/usr/local/bin:/bin")

        let withBoth = ScriptEnvironment.fallback(
            inherited: ["PATH": "/usr/local/bin:/usr/bin:/opt/homebrew/bin"])
        #expect(withBoth["PATH"] == "/usr/local/bin:/usr/bin:/opt/homebrew/bin")
    }

    @Test func fallbackTwiceIsTheSameAsOnce() {
        let once = ScriptEnvironment.fallback(inherited: ["PATH": "/usr/bin"])

        #expect(ScriptEnvironment.fallback(inherited: once) == once)
    }
}
