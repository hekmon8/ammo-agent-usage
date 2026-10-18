import XCTest
import QuotaCore
@testable import QuotaPhone

final class QuotaSpectrumModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    func testSyncedGitHubUnknownNeverAppearsAsExhaustedOrExpiringQuota() throws {
        let unknown = QuotaWindow.providerValue(id: "github-unknown", providerID: "github-actions", accountID: "synthetic",
            alias: "Synthetic", key: "cost-spend", unit: .money, currency: "USD", availability: .unavailable,
            remainingBps: nil, amount: nil, limit: nil, quality: .unknown, source: .officialAPI, outcome: .error,
            observedAt: now, staleAt: now, windowKind: .calendar, duration: nil, resetsAt: nil,
            startsAt: nil, periodID: "github-actions-user-2026-10")
        let wire = try SnapshotCodec.encode(Snapshot.make(windows: [unknown], deviceID: "synthetic", epoch: "synthetic", sequence: 1, capturedAt: now))
        let received = try XCTUnwrap(SnapshotCodec.decode(wire).windows.first)
        let value = QuotaPresentation(window: received, now: now)
        XCTAssertEqual(value.state, .unavailable)
        XCTAssertNil(received.amount); XCTAssertNil(received.remainingBps)
        let model = QuotaSpectrumModel([value], now: now)
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.expiring.isEmpty)
    }

    private func present(_ id: String, provider: String = "codex", bps: Int? = 5_000, unit: QuotaWindow.Unit = .percent,
                         resetsIn: TimeInterval? = 3_600, outcome: FetchOutcome = .ok, offline: Bool = false) -> QuotaPresentation {
        QuotaPresentation(window: .providerValue(
            id: id, providerID: provider, accountID: "a", alias: "A", key: id, unit: unit, currency: nil,
            remainingBps: bps, amount: bps == nil ? "5" : nil, limit: nil, quality: .reported, source: .officialAPI, outcome: outcome,
            observedAt: now, staleAt: now.addingTimeInterval(86_400 * 3), windowKind: .rolling, duration: 18_000,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }), now: now, offline: offline)
    }

    private func expiring(_ values: [QuotaPresentation]) -> [String] {
        QuotaSpectrumModel(values, now: now).expiring.map(\.id)
    }

    func testNonRatioWindowsAreExcluded() {
        let model = QuotaSpectrumModel([present("pct"), present("money", bps: nil, unit: .money), present("credits", bps: nil, unit: .credits)], now: now)
        XCTAssertEqual(model.entries.map(\.id), ["pct"])
        XCTAssertTrue(QuotaSpectrumModel([present("money", bps: nil, unit: .money)], now: now).isEmpty)
        // A money budget that also reports bps is still not a percentage quota.
        XCTAssertTrue(QuotaSpectrumModel([present("budget", bps: 6_000, unit: .money)], now: now).isEmpty)
    }

    func testSnapshotOrderAndProviderGroupingArePreserved() {
        let model = QuotaSpectrumModel([present("c1", provider: "codex", bps: 9_000), present("z1", provider: "zcode", bps: 1_000),
                                        present("c2", provider: "codex", bps: 2_000)], now: now)
        XCTAssertEqual(model.entries.map(\.id), ["c1", "c2", "z1"])
        XCTAssertEqual(model.entries.map(\.startsProvider), [true, false, true])
    }

    func testExpiringHorizonBoundary() {
        XCTAssertEqual(expiring([present("in", resetsIn: 24 * 3600 - 60)]), ["in"])
        XCTAssertEqual(expiring([present("edge", resetsIn: 24 * 3600)]), [])
    }

    func testExpiringRemainingBoundary() {
        XCTAssertEqual(expiring([present("ok", bps: 3_000)]), ["ok"])
        XCTAssertEqual(expiring([present("low", bps: 2_999)]), [])
    }

    func testPastMissingAndHistoricalResetsAreNotExpiring() {
        XCTAssertEqual(expiring([present("past", resetsIn: -60)]), [])
        XCTAssertEqual(expiring([present("none", resetsIn: nil)]), [])
        XCTAssertEqual(expiring([present("offline", offline: true)]), [])
        XCTAssertEqual(expiring([present("failed", outcome: .error)]), [])
    }

    func testCountdownFormatting() {
        XCTAssertEqual(QuotaSpectrumModel.Countdown(40 * 60), .minutes(40))
        XCTAssertEqual(QuotaSpectrumModel.Countdown(3 * 3600), .hours(3))
        XCTAssertEqual(QuotaSpectrumModel.Countdown(59 * 60 + 10), .minutes(59))
        XCTAssertEqual(QuotaSpectrumModel.Countdown(59 * 60 + 40), .hours(1))
        XCTAssertEqual(QuotaSpectrumModel.Countdown(2.5 * 3600), .hours(3))
    }

    func testExpiringListIsSortedBySoonestReset() {
        let model = QuotaSpectrumModel([present("late", provider: "codex", resetsIn: 7_200), present("soon", provider: "zcode", resetsIn: 600),
                                        present("mid", provider: "codex", resetsIn: 3_600)], now: now)
        XCTAssertEqual(model.expiring.map(\.id), ["soon", "mid", "late"])
        XCTAssertEqual(model.entries.map(\.id), ["late", "mid", "soon"])
    }

    func testRayCountAndJitterBounds() {
        XCTAssertEqual(QuotaSpectrumModel.raysPerSector(1), 12)
        XCTAssertEqual(QuotaSpectrumModel.raysPerSector(20), 8)
        XCTAssertEqual(QuotaSpectrumModel.raysPerSector(100), 3)
        for s in 0..<10 { for k in 0..<12 {
            let j = QuotaSpectrumModel.jitter(sector: s, ray: k)
            XCTAssertTrue((0.82...1.0).contains(j))
        } }
    }

    func testTapGeometryPicksSectorCenterAndOutside() {
        // Four windows on one 292pt canvas: sectors run clockwise from 12 o'clock.
        let model = QuotaSpectrumModel(["a", "b", "c", "d"].map { present($0) }, now: now)
        let g = QuotaSpectrumView.Geometry(model, size: CGSize(width: 292, height: 292))
        let band = g.inner + g.span / 2
        func tap(_ i: Int) -> CGPoint { g.point(g.sectors[i].start + g.sectors[i].width / 2, band) }
        XCTAssertEqual((0..<4).map { g.sector(at: tap($0)) }, [0, 1, 2, 3])
        XCTAssertNil(g.sector(at: g.center))
        XCTAssertTrue(g.isCenter(g.center))
        XCTAssertNil(g.sector(at: CGPoint(x: 0, y: 0)))
    }

    func testSectorsAndGapsCloseTheCircle() {
        // Mixed providers: provider starts must not double-count their gap.
        let model = QuotaSpectrumModel(["codex", "codex", "claude", "zcode", "zcode", "grok"].enumerated().map { present("w\($0.offset)", provider: $0.element) }, now: now)
        let g = QuotaSpectrumView.Geometry(model, size: CGSize(width: 292, height: 292))
        let lastGap = model.entries.last!.startsProvider ? 0.07 : 0.03
        let end = g.sectors.last!.start + g.sectors.last!.width + lastGap / 2
        XCTAssertEqual(end, -Double.pi / 2 + 2 * .pi, accuracy: 1e-9)
    }
}
