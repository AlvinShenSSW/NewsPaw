import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

// MARK: - Criteria 1–4 and 12

@MainActor
@Suite("Refresher")
struct RefresherTests {
    // MARK: Criterion 1: targets and cap

    @Test("a whole-library refresh requests every feed that is not paused exactly once; paused and web-page sources get none")
    func libraryTargets() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createCategory(name: "Other", icon: .book)
        try await fixture.addFeed("one")
        try await fixture.addFeed("two")
        try await fixture.addFeed("three", category: other.id)
        try await fixture.addFeed("paused", paused: true)
        try await fixture.addFeed("page", kind: .webpage)
        try await fixture.addFeed("github", kind: .github)
        let transport = CountingTransport { CountingTransport.feed($0) }

        let results = try await Refresher(library: fixture.library, transport: transport).refresh(.library)

        #expect(transport.received.map(\.absoluteString).sorted() == ["one", "three", "two"].map(RefreshFixture.address).sorted())
        #expect(results.count == 3)
        #expect(results.values.allSatisfy { $0 == .outcome(.collected(newArticles: 1, complete: true)) })
    }

    @Test("a category refresh requests only that category's targets; a source refresh only that source; a paused source's refresh nothing")
    func narrowerScopes() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createCategory(name: "Other", icon: .book)
        try await fixture.addFeed("one")
        try await fixture.addFeed("paused", paused: true)
        try await fixture.addFeed("page", kind: .webpage)
        let elsewhere = try await fixture.addFeed("elsewhere", category: other.id)
        let pausedElsewhere = try await fixture.addFeed("pausedelsewhere", category: other.id, paused: true)
        let transport = CountingTransport { CountingTransport.feed($0) }
        let refresher = Refresher(library: fixture.library, transport: transport)

        try await refresher.refresh(.category(fixture.categoryID))
        #expect(transport.received.map(\.absoluteString) == [RefreshFixture.address("one")])

        try await refresher.refresh(.source(elsewhere.id))
        #expect(transport.received.map(\.absoluteString) == [RefreshFixture.address("one"), RefreshFixture.address("elsewhere")])

        let results = try await refresher.refresh(.source(pausedElsewhere.id))
        #expect(results.isEmpty)
        #expect(transport.received.count == 2)
    }

    @Test("never more than 4 in flight; one stalled and one failing source do not hold back the other four")
    func stalledSourceDoesNotHoldBackOthers() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        var sources: [String: Source] = [:]
        for name in ["a", "b", "c", "d", "failing", "stalled"] {
            sources[name] = try await fixture.addFeed(name)
        }
        let transport = CountingTransport { url in
            switch url.absoluteString {
            case RefreshFixture.address("stalled"):
                try await Task.sleep(for: .seconds(600))
                throw TransportFailure.timedOut
            case RefreshFixture.address("failing"):
                throw TransportFailure.unreachable
            default:
                try await Task.sleep(for: .milliseconds(20))
                return CountingTransport.feed(url)
            }
        }
        let refresher = Refresher(library: fixture.library, transport: transport)
        let ended = CallCounter()
        let fiveEnded = Signal()
        refresher.onCollectionEnded = { _ in
            if ended.next() == 4 {
                fiveEnded.fire()
            }
        }

        let run = Task { try await refresher.refresh(.library) }
        await fiveEnded.wait()

        for name in ["a", "b", "c", "d"] {
            let source = try await fixture.source(sources[name]!.id)
            #expect(source.lastSuccessAt == fixture.clock.now(), "\(name)")
            #expect(source.lastError == nil, "\(name)")
            #expect(try await fixture.state(of: source.id).contains { $0.hasPrefix("article:") }, "\(name) stored its article")
        }
        #expect(try await fixture.source(sources["failing"]!.id).lastError == "unreachable")
        #expect(refresher.collecting == [sources["stalled"]!.id])
        #expect(transport.inFlight == 1)
        #expect(transport.mostInFlight <= 4)

        refresher.cancelAll()
        let results = try await run.value
        #expect(results[sources["stalled"]!.id] == .cancelled)
        #expect(try await fixture.source(sources["stalled"]!.id).lastError == nil)
        #expect(try await fixture.library.lastRefreshAt() == nil, "a cancelled run records nothing")
    }

    // MARK: Criterion 2 and 12: joining

    @Test("a refresh asked for while a run holds the source joins it: one request, and it returns after that collection ends")
    func joining() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let held = try await fixture.addFeed("held")
        let other = try await fixture.addFeed("other")
        let entered = Signal()
        let release = Signal()
        let transport = CountingTransport { url in
            if url.absoluteString == RefreshFixture.address("held") {
                entered.fire()
                await release.wait()
            }
            return CountingTransport.feed(url)
        }
        let refresher = Refresher(library: fixture.library, transport: transport)
        let otherEnded = Signal()
        refresher.onCollectionEnded = { id in
            if id == other.id { otherEnded.fire() }
        }

        // "Update Now" holds the source; then a whole-library run and a
        // second "Update Now" join it.
        let first = Task { try await refresher.refresh(.source(held.id)) }
        await entered.wait()
        let returned = Holder<Bool>()
        let library = Task {
            let results = try await refresher.refresh(.library)
            returned.set(true)
            return results
        }
        let second = Task { try await refresher.refresh(.source(held.id)) }
        await otherEnded.wait()
        #expect(returned.value == nil, "the run waits for the joined collection")
        #expect(refresher.collecting == [held.id])

        release.fire()
        let results = try await library.value
        #expect(try await first.value[held.id] == .outcome(.collected(newArticles: 1, complete: true)))
        #expect(try await second.value[held.id] == .outcome(.collected(newArticles: 1, complete: true)))
        #expect(results[held.id] == .outcome(.collected(newArticles: 1, complete: true)))
        #expect(transport.requests(for: RefreshFixture.address("held")) == 1)
        #expect(transport.requests(for: RefreshFixture.address("other")) == 1)
        #expect(refresher.collecting.isEmpty)
    }

    @Test("two overlapping runs never have more than 4 in flight and request each source once")
    func overlappingRuns() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createCategory(name: "Other", icon: .book)
        for index in 0..<6 {
            try await fixture.addFeed("first\(index)")
            try await fixture.addFeed("second\(index)", category: other.id)
        }
        // Nothing answers until both runs have read their targets, so the
        // second can only join.
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            try await Task.sleep(for: .milliseconds(30))
            return CountingTransport.feed(url)
        }
        let refresher = Refresher(library: fixture.library, transport: transport)

        async let whole = refresher.refresh(.library)
        async let category = refresher.refresh(.category(other.id))
        try await Task.sleep(for: .milliseconds(300))
        go.fire()
        let (wholeResults, categoryResults) = try await (whole, category)

        #expect(wholeResults.count == 12)
        #expect(categoryResults.count == 6)
        #expect(transport.received.count == 12)
        #expect(Set(transport.received).count == 12)
        #expect(transport.mostInFlight <= 4)
        #expect(transport.mostInFlight >= 2)
    }

    // MARK: Criterion 3: the recorded time

    @Test("a whole-library run records its end time; category and source runs record nothing")
    func recordedOnlyByWholeLibraryRuns() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one")
        let refresher = Refresher(library: fixture.library, transport: CountingTransport { CountingTransport.feed($0) })

        try await refresher.refresh(.category(fixture.categoryID))
        try await refresher.refresh(.source(source.id))
        #expect(try await fixture.library.lastRefreshAt() == nil)

        fixture.clock.advance(seconds: 300)
        try await refresher.refresh(.library)
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
    }

    @Test("a run in which every attempted source failed records nothing; one success among failures records")
    func everyAttemptFailed() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        try await fixture.addFeed("one")
        try await fixture.addFeed("two")
        let failing = Refresher(library: fixture.library, transport: CountingTransport { _ in throw TransportFailure.unreachable })
        try await failing.refresh(.library)
        #expect(try await fixture.library.lastRefreshAt() == nil)

        let mixed = Refresher(library: fixture.library, transport: CountingTransport { url in
            if url.absoluteString == RefreshFixture.address("one") { throw TransportFailure.unreachable }
            return CountingTransport.feed(url)
        })
        try await mixed.refresh(.library)
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
    }

    @Test("a run with no source to attempt records its time: an empty library; one of paused and web-page sources only")
    func nothingToAttempt() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let transport = CountingTransport { CountingTransport.feed($0) }
        let refresher = Refresher(library: fixture.library, transport: transport)
        try await refresher.refresh(.library)
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())

        try await fixture.addFeed("paused", paused: true)
        try await fixture.addFeed("page", kind: .webpage)
        fixture.clock.advance(seconds: 120)
        try await refresher.refresh(.library)
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
        #expect(transport.received.isEmpty)
    }

    @Test("due: nothing recorded, exactly the interval or older, or a time in the future; not when younger; never when manual",
          arguments: [RefreshInterval.fifteenMinutes, .thirtyMinutes, .sixtyMinutes])
    func due(_ interval: RefreshInterval) async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let now = fixture.clock.now()
        let period = TimeInterval(interval.rawValue * 60)

        #expect(try await library.refreshIsDue(every: interval), "nothing recorded")
        #expect(try await library.refreshIsDue(every: .manualOnly) == false, "manual, nothing recorded")
        let cases: [(TimeInterval, Bool, String)] = [
            (1, false, "a second ago"),
            (period - 1, false, "a second younger than the interval"),
            (period, true, "exactly the interval"),
            (period + 1, true, "older"),
            (86_400 * 3, true, "days older"),
            (-60, true, "in the future"),
        ]
        for (age, expected, label) in cases {
            try await library.setLastRefreshAt(now.addingTimeInterval(-age))
            #expect(try await library.refreshIsDue(every: interval) == expected, "\(label)")
            #expect(try await library.refreshIsDue(every: .manualOnly) == false, "manual: \(label)")
        }
    }

    // MARK: Criterion 4: cancellation

    @Test("cancelling leaves unfinished sources exactly as they were, keeps finished ones, returns, and makes no request for waiting ones; a later refresh collects")
    func cancellation() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let fast = try await fixture.addFeed("a-fast")
        var blocked: [Source] = []
        for index in 0..<5 {
            blocked.append(try await fixture.addFeed("blocked\(index)"))
        }
        // Earlier results, so that "exactly as they were" covers articles,
        // seen rows and the status columns.
        for source in blocked {
            _ = try await FeedCollector(transport: CountingTransport { CountingTransport.feed($0) }).collect(source.id, in: fixture.library)
            try await fixture.library.insertSeen(sourceID: source.id, externalIDHash: "earlier", lastSeenAt: fixture.clock.now())
        }
        fixture.clock.advance(seconds: 600)
        var before: [UUID: [String]] = [:]
        for source in blocked {
            before[source.id] = try await fixture.state(of: source.id)
        }
        let unblocked = Holder<Bool>()
        let fourBlocked = Signal()
        let transport = CountingTransport { url in
            if url.absoluteString != RefreshFixture.address("a-fast"), unblocked.value == nil {
                fourBlocked.fire()
                try await Task.sleep(for: .seconds(600))
            }
            return CountingTransport.feed(url)
        }
        let refresher = Refresher(library: fixture.library, transport: transport)
        let run = Task { try await refresher.refresh(.library) }
        // The fast source sorts first and ends; four blocked sources then
        // hold every slot and the fifth waits.
        while transport.received.count < 5 || transport.inFlight < 4 {
            await fourBlocked.wait()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refresher.collecting.count == 5)

        refresher.cancelAll()
        unblocked.set(true)
        let results = try await run.value

        #expect(results[fast.id] == .outcome(.collected(newArticles: 1, complete: true)))
        #expect(try await fixture.source(fast.id).lastSuccessAt == fixture.clock.now())
        for source in blocked {
            #expect(results[source.id] == .cancelled)
            #expect(try await fixture.state(of: source.id) == before[source.id], "\(source.name)")
        }
        #expect(transport.received.count == 5, "the waiting source made no request")
        #expect(try await fixture.library.lastRefreshAt() == nil)
        #expect(refresher.collecting.isEmpty)

        // A refresh started after the cancellation collects normally.
        fixture.clock.advance(seconds: 60)
        let again = try await refresher.refresh(.library)
        #expect(again.count == 6)
        #expect(!again.values.contains(.cancelled))
        for source in blocked {
            #expect(try await fixture.source(source.id).lastSuccessAt == fixture.clock.now())
        }
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
    }
}

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
    @MainActor
    @Suite("Refresher with several hundred sources")
    struct RefresherCapTests {
        @Test("several hundred sources: each requested once, never more than 4 in flight, and every run ends")
        func severalHundredSources() async throws {
            let fixture = try await RefreshFixture.make()
            defer { fixture.remove() }
            for index in 0..<300 {
                try await fixture.addFeed("source\(index)")
            }
            // Nothing answers until the three runs have read their targets,
            // so the later two can only join.
            let go = Signal()
            let transport = CountingTransport { url in
                await go.wait()
                // Uneven answer times, so that slots are freed while others
                // are waiting and new ones are asked for.
                let digits = url.absoluteString.filter(\.isNumber)
                try await Task.sleep(for: .milliseconds(1 + (Int(digits) ?? 0) % 7))
                return CountingTransport.feed(url)
            }
            let refresher = Refresher(library: fixture.library, transport: transport)

            async let whole = refresher.refresh(.library)
            async let again = refresher.refresh(.library)
            async let category = refresher.refresh(.category(fixture.categoryID))
            try await Task.sleep(for: .milliseconds(300))
            go.fire()
            let results = try await [whole, again, category]

            #expect(results.allSatisfy { $0.count == 300 })
            #expect(transport.received.count == 300)
            #expect(Set(transport.received).count == 300)
            #expect(transport.mostInFlight == 4)
            #expect(refresher.collecting.isEmpty)
        }
    }
}
