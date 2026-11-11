import NewsPawKit
import Testing

@Suite("Partition")
struct PartitionTests {
    @Test("raw values match the configuration file")
    func rawValues() {
        #expect(Partition.allCases.map(\.rawValue) == ["normal", "adult"])
        #expect(Partition(rawValue: "normal") == .normal)
        #expect(Partition(rawValue: "adult") == .adult)
        #expect(Partition(rawValue: "Adult") == nil)
    }
}
