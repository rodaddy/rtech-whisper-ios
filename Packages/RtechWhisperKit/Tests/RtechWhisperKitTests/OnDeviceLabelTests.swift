import Testing

@testable import RtechWhisperKit

/// On-device takes are labelled and synced as on-device.
@Suite struct OnDeviceLabelTests {
    @Test func historyProviderFollowsTheSource() {
        #expect(HistoryFormatting.provider(for: .onDevice) == HistoryFormatting.onDeviceProvider)
        #expect(HistoryFormatting.provider(for: .hub) == HistoryFormatting.hubProvider)
        #expect(HistoryFormatting.provider(for: nil) == HistoryFormatting.hubProvider)
    }

    @Test func aDoneOnDeviceTakeIsNotProvisional() {
        #expect(QueuedDictation.sourceLabel(source: .onDevice, isDone: true, edited: false, cleaned: false) == "On-device")
        #expect(QueuedDictation.sourceLabel(source: .onDevice, isDone: true, edited: true, cleaned: false) == "On-device, edited by you")
    }

    @Test func aWaitingOnDeviceTakeStaysProvisional() {
        #expect(QueuedDictation.sourceLabel(source: .onDevice, isDone: false, edited: false, cleaned: false) == "On-device, will update")
        #expect(QueuedDictation.sourceLabel(source: .onDevice, isDone: false, edited: true, cleaned: false) == "On-device, edited by you")
    }

    @Test func hubAndEmptyLabelsAreUnchanged() {
        #expect(QueuedDictation.sourceLabel(source: .hub, isDone: true, edited: false, cleaned: true) == "Whisper, cleaned up")
        #expect(QueuedDictation.sourceLabel(source: .hub, isDone: true, edited: false, cleaned: false) == "Whisper")
        #expect(QueuedDictation.sourceLabel(source: .hub, isDone: true, edited: true, cleaned: true) == "Whisper, edited by you")
        #expect(QueuedDictation.sourceLabel(source: nil, isDone: false, edited: true, cleaned: false) == "Edited by you")
        #expect(QueuedDictation.sourceLabel(source: nil, isDone: false, edited: false, cleaned: false) == "No text yet")
    }
}
