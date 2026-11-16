import Foundation
import Testing

import OpenRayCore

// The output here is written by hand in the form `env -0` prints. No shell is run, and the
// values are made up.
@Suite struct ShellEnvironmentParserTests {
    private let start = "__OPENRAY_ENV_START_1D4C__"
    private let end = "__OPENRAY_ENV_END_1D4C__"

    /// The entries as `env -0` prints them, each ended by a NUL, between the sentinels.
    private func output(
        _ entries: [String], before: String = "", after: String = ""
    ) -> String {
        var text = before + start
        for entry in entries {
            text += entry + "\0"
        }
        return text + end + after
    }

    private func variables(in output: String) -> [String: String]? {
        ShellEnvironmentParser.variables(in: output, start: start, end: end)
    }

    @Test func entriesBetweenTheSentinels() {
        let text = output([
            "HOME=/Users/me", "PATH=/opt/homebrew/bin:/usr/bin:/bin", "LANG=de_DE.UTF-8",
        ])

        #expect(
            variables(in: text) == [
                "HOME": "/Users/me",
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                "LANG": "de_DE.UTF-8",
            ])
    }

    @Test func whatRcFilesPrintBeforeAndAfterIsNotRead() {
        let text = output(
            ["EDITOR=vim"],
            before: "Welcome back!\nFAKE=1\0Last login: today\n",
            after: "\nlogout\nOTHER=2\0")

        #expect(variables(in: text) == ["EDITOR": "vim"])
    }

    @Test func valueWithLineEndsAndEqualsSigns() {
        let text = output(["PROMPT=line one\nline two\r\n", "OPTIONS=a=1 b=2", "EQUALS=="])

        #expect(
            variables(in: text) == [
                "PROMPT": "line one\nline two\r\n",
                "OPTIONS": "a=1 b=2",
                "EQUALS": "=",
            ])
    }

    @Test func emptyValueIsAVariable() {
        #expect(variables(in: output(["EMPTY=", "SET=1"])) == ["EMPTY": "", "SET": "1"])
    }

    @Test func entriesWithoutANameOrWithoutAnEqualsSignAreDropped() {
        let text = output(["NOVALUE", "=nameless", "", "KEPT=1"])

        #expect(variables(in: text) == ["KEPT": "1"])
    }

    @Test func variablesThatDescribeTheCapturingShellAreDropped() {
        let text = output([
            "_=/usr/bin/env", "SHLVL=2", "PWD=/Users/me", "OLDPWD=/", "HOME=/Users/me",
            // Only the exact names: these are somebody's own.
            "PWD_BACKUP=/tmp", "_X=1",
        ])

        #expect(
            variables(in: text) == ["HOME": "/Users/me", "PWD_BACKUP": "/tmp", "_X": "1"])
    }

    @Test func valueThatBeginsWithAnAccentIsKeptWhole() {
        // To Swift the "=" and the accent are one character.
        let text = output(["ACCENT=\u{301}x"])

        #expect(variables(in: text) == ["ACCENT": "\u{301}x"])
    }

    @Test func noEnvironmentBetweenTheSentinels() {
        #expect(variables(in: output([])) == [:])
    }

    @Test func outputWithoutBothSentinelsInOrderIsNoAnswer() {
        #expect(variables(in: "") == nil)
        #expect(variables(in: "HOME=/Users/me\0") == nil)
        // The shell was killed while it printed.
        #expect(variables(in: start + "HOME=/Users/me\0PATH=/usr") == nil)
        #expect(variables(in: "HOME=/Users/me\0" + end) == nil)
        #expect(variables(in: end + "HOME=/Users/me\0" + start) == nil)
    }
}
