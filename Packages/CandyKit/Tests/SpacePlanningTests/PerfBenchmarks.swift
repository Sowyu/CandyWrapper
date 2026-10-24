import Foundation
import Darwin
import Testing
import SpaceModel
import SpacePlanning

/// Picked up by scripts/perf-review's PerfBenchmarks filter. No app or plaintext files.
@Suite(.serialized)
struct SpacePlanningPerfBenchmarks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_BENCH"] == "1"))
    func targetSizeSearch() throws {
        var pages: [PageID: PageRecord] = [:]
        var blocks: [BlockID: BlockRecord] = [:]
        for n in 1...22_000 {
            pages[id(n)] = page("Project notes \(n)", parent: n > 2_000 ? 1 + n % 2_000 : nil)
        }
        for n in 1...100_000 {
            blocks[id(n + 22_000)] = block("Daily project notes \(n). Review the design, plan the next meeting and buy café supplies.",
                                          page: 1 + n % 2_000)
        }
        let clock = ContinuousClock()
        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        let start = clock.now
        let index = SearchIndex(pages: pages, blocks: blocks)
        let build = milliseconds(start.duration(to: clock.now))
        var after = malloc_statistics_t()
        malloc_zone_statistics(nil, &after)
        emit("space_search_build", samples: [build], details: ["pages": pages.count, "blocks": blocks.count,
                                                               "index_heap_bytes": Int(after.size_in_use) - Int(before.size_in_use)])
        for (label, query) in [("sparse", "10000"), ("missing", "absent"), ("common", "cafe plan"), ("titles", "project")] {
            _ = index.search(query)
            var samples: [Double] = []
            for _ in 0..<21 {
                let start = clock.now
                let result = index.search(query)
                samples.append(milliseconds(start.duration(to: clock.now)))
                if label == "missing" { #expect(result.content.isEmpty && result.titles.isEmpty) }
                if label == "common" { #expect(result.content.count == 50) }
                if label == "titles" { #expect(result.titles.count == 22_000) }
            }
            emit("space_search_" + label, samples: samples, details: [:])
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func emit(_ name: String, samples: [Double], details: [String: Int]) {
        let sorted = samples.sorted()
        var result: [String: Any] = ["name": name, "runs": sorted.count, "median_ms": sorted[sorted.count / 2],
                                     "min_ms": sorted.first!, "max_ms": sorted.last!,
                                     "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]]
        for (key, value) in details { result[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PERF " + String(decoding: data, as: UTF8.self))
    }
}
