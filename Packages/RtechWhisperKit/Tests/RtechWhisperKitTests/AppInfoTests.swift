import Foundation
import Testing

@testable import RtechWhisperKit

@Test func displayNameIsThePhoneFacingName() {
    #expect(AppInfo.displayName == "rTech Whisper")
}

@Test func versionCombinesShortStringAndBuild() {
    let info = [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1"
    ]
    #expect(AppInfo.version(info: info) == "0.1.0 (1)")
}

@Test func versionIsDevWhenBothKeysAreAbsent() {
    #expect(AppInfo.version(info: [:]) == "dev")
}

@Test func versionFallsBackWhenOneKeyIsAbsent() {
    #expect(AppInfo.version(info: ["CFBundleShortVersionString": "0.2.0"]) == "0.2.0")
    #expect(AppInfo.version(info: ["CFBundleVersion": "7"]) == "dev (7)")
}
