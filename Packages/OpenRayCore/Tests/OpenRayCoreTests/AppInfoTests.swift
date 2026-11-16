import Testing

@testable import OpenRayCore

@Test func appNameIsOpenRay() {
    #expect(AppInfo.name == "OpenRay")
}

@Test func versionLineHasTheVersionAndTheBuild() {
    #expect(AppInfo.versionLine(version: "0.1.0", build: "123") == "0.1.0 (123)")
}

@Test func versionLineWithoutABuildIsTheVersion() {
    #expect(AppInfo.versionLine(version: "0.1.0", build: nil) == "0.1.0")
}

// A process without an Info.plist, such as a test run, has neither. A build number alone says
// nothing a person could use.
@Test(arguments: [nil, "123"])
func versionLineWithoutAVersionSaysSo(_ build: String?) {
    #expect(AppInfo.versionLine(version: nil, build: build) == "Unknown version")
}
