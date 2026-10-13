import Foundation
import Testing
@testable import RtechWhisperKit

@Suite struct TranscriptionLanguageTests {
    @Test func autoSendsNoLanguageAndUsesThePhoneLocale() {
        let auto = TranscriptionLanguage.auto
        #expect(auto.code == "auto")
        #expect(auto.hubLanguage == nil)
        #expect(auto.locale == nil)
        #expect(TranscriptionLanguage.all.first == auto)
    }

    @Test func regionalCodesSendTheirISO6391BaseToTheHub() throws {
        #expect(try #require(TranscriptionLanguage(code: "zh-CN")).hubLanguage == "zh")
        #expect(try #require(TranscriptionLanguage(code: "en-GB")).hubLanguage == "en")
        #expect(try #require(TranscriptionLanguage(code: "fr")).hubLanguage == "fr")
    }

    @Test func aChoiceSetsTheRecognizerLocale() throws {
        #expect(try #require(TranscriptionLanguage(code: "en-GB")).locale == Locale(identifier: "en-GB"))
        #expect(try #require(TranscriptionLanguage(code: "de")).locale == Locale(identifier: "de"))
    }

    @Test func theListMatchesTheDesktopRegistry() {
        #expect(TranscriptionLanguage.all.count == 61)
        #expect(Set(TranscriptionLanguage.all.map(\.code)).count == 61)
        #expect(TranscriptionLanguage(code: "xx") == nil)
    }

    @MainActor @Test func theChoiceIsStoredAndDefaultsToAuto() throws {
        let defaults = try #require(UserDefaults(suiteName: "lang-\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        #expect(store.transcriptionLanguage == .auto)
        store.transcriptionLanguage = try #require(TranscriptionLanguage(code: "es"))
        #expect(AppSettingsStore(defaults: defaults).transcriptionLanguage.code == "es")
        defaults.set("gone", forKey: AppSettingsStore.Key.transcriptionLanguage)
        #expect(AppSettingsStore(defaults: defaults).transcriptionLanguage == .auto)
    }
}
