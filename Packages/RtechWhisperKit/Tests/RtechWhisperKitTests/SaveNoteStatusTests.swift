import Foundation
import Testing
@testable import RtechWhisperKit

struct SaveNoteStatusTests {
    struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }

    @Test func failureCarriesTheErrorText() {
        let status = SaveNoteStatus(failure: Boom())
        #expect(status == .failed("Could not save the note: disk full"))
        #expect(status.message == "Could not save the note: disk full")
        #expect(status.isFailure)
        #expect(!status.isSaved("hi"))
    }

    @Test func savedMatchesOnlyItsText() {
        let status = SaveNoteStatus.saved("hi")
        #expect(status.isSaved("hi"))
        #expect(!status.isSaved("other"))
        #expect(status.message == "Saved to notes.")
        #expect(!status.isFailure)
    }

    @Test func idleShowsNothing() {
        #expect(SaveNoteStatus.idle.message == nil)
    }

    // A's save ends after B is on screen and B's own save has started.
    @Test func aSaveThatOutlivesItsTextLeavesTheNewerStatusAlone() throws {
        var status = SaveNoteStatus.idle
        let aToken = status.beginSaving("A")
        let a = try #require(aToken)
        status = .idle  // A new file was picked.
        let bToken = status.beginSaving("B")
        let b = try #require(bToken)
        status.finishSaving(a, error: nil)
        #expect(status == .saving(b, "B"))
        status.finishSaving(a, error: Boom(), logOutdated: { _ in })
        #expect(status == .saving(b, "B"))
        #expect(status.beginSaving("B") == nil)

        status.finishSaving(b, error: nil)
        #expect(status == .saved("B"))
        var failed = SaveNoteStatus.idle
        let cToken = failed.beginSaving("B")
        let c = try #require(cToken)
        failed.finishSaving(c, error: Boom())
        #expect(failed == .failed("Could not save the note: disk full"))
    }

    // Two saves of the same text; the first ends while the second is in flight.
    @Test func aSaveIsMatchedByItsTokenNotItsText() throws {
        var status = SaveNoteStatus.idle
        let firstToken = status.beginSaving("same")
        let first = try #require(firstToken)
        status = .idle  // The same text picked again, e.g. the same file re-uploaded.
        let secondToken = status.beginSaving("same")
        let second = try #require(secondToken)
        status.finishSaving(first, error: Boom(), logOutdated: { _ in })
        #expect(status == .saving(second, "same"))
        #expect(status.isSaving)
        status.finishSaving(first, error: nil)
        #expect(status == .saving(second, "same"))
        status.finishSaving(second, error: nil)
        #expect(status == .saved("same"))
    }

    // An outdated save that failed is logged, not dropped; a success is not.
    @Test func anOutdatedFailedSaveIsLogged() throws {
        var status = SaveNoteStatus.idle
        let aToken = status.beginSaving("A")
        let a = try #require(aToken)
        status = .idle
        var logged: [String] = []
        status.finishSaving(a, error: nil, logOutdated: { logged.append($0) })
        #expect(logged.isEmpty)
        status.finishSaving(a, error: Boom(), logOutdated: { logged.append($0) })
        #expect(logged == ["An earlier note save failed after its screen moved on: disk full"])
        #expect(status == .idle)
    }
}
