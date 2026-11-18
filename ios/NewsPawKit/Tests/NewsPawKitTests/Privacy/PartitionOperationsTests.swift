import NewsPawKit
import Testing

/// RD19 review round 4: one partition operation at a time, ended only by
/// the token that began it, and the table of what each refuses.
@Suite("Partition operations")
struct PartitionOperationsTests {
    @Test("a second operation is refused while one runs, and changes nothing")
    func oneAtATime() throws {
        var operations = PartitionOperations()
        let firstBegun = operations.begin(.turnOff)
        let first = try #require(firstBegun)
        let secondTurnOff = operations.begin(.turnOff)
        let clear = operations.begin(.clearBrowsingData)
        let move = operations.begin(.categoryMove)
        #expect(secondTurnOff == nil && clear == nil && move == nil)
        #expect(operations.running == .turnOff)
        let ended = operations.end(first)
        #expect(ended)
        #expect(operations.running == nil)
        let next = operations.begin(.clearBrowsingData)
        #expect(next != nil)
    }

    @Test("only the token that began an operation ends it")
    func onlyItsTokenEndsIt() throws {
        var operations = PartitionOperations()
        let earlierBegun = operations.begin(.turnOff)
        let earlier = try #require(earlierBegun)
        operations.end(earlier)
        let runningBegun = operations.begin(.turnOff)
        let running = try #require(runningBegun)
        // The token of an operation that has ended, of the same kind: a
        // request that was refused holds none at all.
        let endedByEarlier = operations.end(earlier)
        #expect(!endedByEarlier)
        #expect(operations.running == .turnOff)
        let endedByRunning = operations.end(running)
        let endedAgain = operations.end(running)
        #expect(endedByRunning && !endedAgain)
        #expect(operations.running == nil)
    }

    @Test("what each operation refuses")
    func table() throws {
        let none = PartitionOperations()
        #expect(!none.refusesUnlock && !none.refusesUnlockCarryingMove && !none.refusesAdultSessions && !none.refusesLibraryEdits)

        var moving = PartitionOperations()
        let moveBegun = moving.begin(.categoryMove)
        _ = try #require(moveBegun)
        #expect(!moving.refusesUnlock)
        #expect(moving.refusesUnlockCarryingMove)
        #expect(!moving.refusesAdultSessions)
        #expect(moving.refusesLibraryEdits)

        for operation in [PartitionOperation.clearBrowsingData, .turnOff] {
            var operations = PartitionOperations()
            let begun = operations.begin(operation)
            _ = try #require(begun)
            #expect(operations.refusesUnlock)
            #expect(operations.refusesUnlockCarryingMove)
            #expect(operations.refusesAdultSessions)
            #expect(!operations.refusesLibraryEdits)
        }
    }
}
