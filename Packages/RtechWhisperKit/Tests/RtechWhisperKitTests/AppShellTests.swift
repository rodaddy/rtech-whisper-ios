import Foundation
import Testing

@testable import RtechWhisperKit

@Test func moreFeaturesAreDictionaryAndUpload() {
    #expect(MoreFeature.allCases.map(\.title) == ["Dictionary", "Snippets", "Upload"])
    #expect(MoreFeature.allCases.map(\.systemImage) == ["book", "text.badge.plus", "square.and.arrow.up"])
}

@Test func hubSummaryShowsTheConfiguredHubWithoutATrailingSlash() {
    let configuration = HubConfiguration(baseURL: URL(string: "https://hub.example.org/")!)
    let summary = HubSettingsSummary(state: .needsKey, configuration: configuration)
    #expect(summary.hubURL == "https://hub.example.org")
    #expect(summary.statusLine == "Not connected")
    #expect(summary.hasStoredKey == false)
}

@Test func hubSummaryNamesTheConnectedDevice() {
    let summary = HubSettingsSummary(state: .connected(HubDevice(id: "dev-1", name: "Rico's iPhone")))
    #expect(summary.statusLine == "Connected as Rico's iPhone")
    #expect(summary.hasStoredKey)
}

@Test func hubSummaryKeepsTheKeyWhenTheCheckFailed() {
    let summary = HubSettingsSummary(state: .stored(.network("offline")))
    #expect(summary.statusLine == "Key stored, but the hub check failed")
    #expect(summary.hasStoredKey)
}
