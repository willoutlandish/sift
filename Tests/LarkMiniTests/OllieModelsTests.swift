import XCTest
@testable import LarkMini

final class OllieModelsTests: XCTestCase {
    func testTodayOrdersShopsAndBuildsPills() {
        let pace: [String: CompanionShopPace] = [
            "crocs": CompanionShopPace(resource: "crocs", name: "CROCS", currency: "USD",
                                       mtd: 31_200, goal: 55_000, expectedByToday: 38_500, gap: -7_300,
                                       progressPct: 57, paceStatus: "behind", basis: "total"),
            "jlo": CompanionShopPace(resource: "jlo", name: "JLO", currency: "USD",
                                     mtd: 32_400, goal: 45_000, expectedByToday: 31_500, gap: 900,
                                     progressPct: 72, paceStatus: "on_track", basis: "total"),
            "ahead": CompanionShopPace(resource: "ahead", name: "AHEAD", currency: "USD",
                                       mtd: 50_000, goal: 40_000, expectedByToday: 30_000, gap: 200,
                                       progressPct: 125, paceStatus: "ahead", basis: "total"),
            "alpha": CompanionShopPace(resource: "alpha", name: "Alpha", currency: "USD",
                                       mtd: nil, goal: nil, expectedByToday: nil, gap: nil,
                                       progressPct: nil, paceStatus: "no_target", basis: "total"),
            "zeta": CompanionShopPace(resource: "zeta", name: "Zeta", currency: "USD",
                                      mtd: nil, goal: 80_000, expectedByToday: nil, gap: nil,
                                      progressPct: nil, paceStatus: "no_data", basis: "total")
        ]
        let snapshot = CompanionTodoSnapshot(total: 6, shops: [], orderedItems: [])
        let activity: [String: CompanionShopActivitySummary] = [
            "crocs": .ready(agents: 3, working: 2),
            "jlo": .ready(agents: 1, working: 1)
        ]
        let model = OllieTodayModel(pace: pace, paceState: .available, snapshot: snapshot, activity: activity)
        XCTAssertEqual(model.shops.map(\.name), ["CROCS", "JLO", "AHEAD", "Alpha", "Zeta"])
        XCTAssertEqual(model.shops[0].pill, .behind("$7.3k"))
        XCTAssertEqual(model.shops[1].pill, .onTrack)
        XCTAssertEqual(model.shops[2].pill, .ahead("$200"))
        XCTAssertEqual(model.shops[3].pill, .noTarget)
        XCTAssertEqual(model.shops[4].pill, .noData)
        XCTAssertEqual(model.summary, "4 with targets · 2 on pace · 1 behind · 1 without targets · 1 without sales data · 3 agents working · 0 waiting for you")
    }


    func testAllShopProgressSumsOnlyWithinOneCurrency() {
        let pace: [String: CompanionShopPace] = [
            "us-a": CompanionShopPace(resource: "us-a", name: "US A", currency: "USD",
                                      mtd: 100, goal: 1000, expectedByToday: 300, gap: -700,
                                      progressPct: 10, paceStatus: "behind", basis: "total"),
            "us-b": CompanionShopPace(resource: "us-b", name: "US B", currency: "USD",
                                      mtd: 200, goal: 2000, expectedByToday: 600, gap: -1400,
                                      progressPct: 10, paceStatus: "behind", basis: "total"),
            "gb-a": CompanionShopPace(resource: "gb-a", name: "GB A", currency: "GBP",
                                      mtd: 50, goal: 100, expectedByToday: 40, gap: 10,
                                      progressPct: 50, paceStatus: "on_track", basis: "total")
        ]
        let model = OllieTodayModel(pace: pace, paceState: .available, snapshot: nil, activity: [:])
        XCTAssertEqual(model.allProgress.count, 2)
        let usd = model.allProgress.first { $0.currency == "USD" }
        XCTAssertEqual(usd?.pace.mtd, 300)
        XCTAssertEqual(usd?.pace.goal, 3000)
        XCTAssertNil(usd?.pace.expectedByToday)
        XCTAssertNil(usd?.pace.gap)
        XCTAssertNil(usd?.pill)
        XCTAssertNotNil(model.allProgress.first { $0.currency == "GBP" })
        XCTAssertEqual(model.allProgress.first { $0.currency == "GBP" }?.pace.mtd, 50)
        XCTAssertNotEqual(usd?.pace.mtd, 350, "currencies must never be added together")
    }


    func testTodaySaysNoSalesDataWhenEveryShopIsEmpty() {
        let pace: [String: CompanionShopPace] = [
            "a": CompanionShopPace(resource: "a", name: "A", currency: "USD",
                                   mtd: nil, goal: 100, expectedByToday: nil, gap: nil,
                                   progressPct: nil, paceStatus: "no_data", basis: "total"),
            "b": CompanionShopPace(resource: "b", name: "B", currency: "USD",
                                   mtd: nil, goal: 200, expectedByToday: nil, gap: nil,
                                   progressPct: nil, paceStatus: "no_data", basis: "total")
        ]
        let model = OllieTodayModel(pace: pace, paceState: .available, snapshot: nil, activity: [:])
        XCTAssertEqual(model.summary, "2 with targets · 0 on pace · 0 behind · 2 without sales data")
    }


    func testAllShopProgressUsesPortfolioTotalsAndElapsedTick() {
        let pace: [String: CompanionShopPace] = [
            "a": CompanionShopPace(resource: "a", name: "A", currency: "USD",
                                   mtd: 100, goal: 1000, expectedByToday: 300, gap: -700,
                                   progressPct: 10, paceStatus: "behind", basis: "total",
                                   metricsThrough: "2026-11-06")
        ]
        let totals = CompanionPaceTotals(
            byCurrency: [
                CompanionPaceCurrencyTotal(currency: "USD", mtd: 300, goal: 3000),
                CompanionPaceCurrencyTotal(currency: "GBP", mtd: 50, goal: 100)
            ],
            behind: 1, unavailableShops: 0, elapsedPct: 20)
        let model = OllieTodayModel(pace: pace, paceState: .available, snapshot: nil,
                                    activity: [:], totals: totals)
        XCTAssertEqual(model.allProgress.count, 1)
        let usd = model.allProgress.first { $0.currency == "USD" }
        XCTAssertEqual(usd?.pace.expectedByToday, 200)
        XCTAssertEqual(usd?.pace.gap, -100)
        XCTAssertEqual(usd?.bar.expectedFraction ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(usd?.pill, .behind("$100"))
        XCTAssertEqual(usd?.pace.metricsThrough, "2026-11-06")
        XCTAssertNotEqual(usd?.pace.mtd, 350, "currencies must never be added together")
        XCTAssertEqual(CompanionPace.metricsText("2026-11-06"), "Friday")
    }

    func testTodaySummaryOmitsUnavailableSources() {
        let pace: [String: CompanionShopPace] = [
            "one": CompanionShopPace(resource: "one", name: "One", currency: "USD",
                                     mtd: 1, goal: 2, expectedByToday: 1, gap: 0,
                                     progressPct: 50, paceStatus: "on_track", basis: "total")
        ]
        let onlyPace = OllieTodayModel(pace: pace, paceState: .available, snapshot: nil,
                                       activity: ["one": .unavailable])
        XCTAssertEqual(onlyPace.summary, "1 with targets · 1 on pace · 0 behind")

        let noSources = OllieTodayModel(pace: pace, paceState: .hidden, snapshot: nil, activity: [:])
        XCTAssertEqual(noSources.summary, "")
        XCTAssertTrue(noSources.shops.isEmpty)
    }

    func testActivityNodeMapsStateSparklineAndCounts() throws {
        let shop = #"""
        {"tabs":[
          {"agent":"agent-a","name":"Creator manager","role":"creator-manager","state":"working",
           "now":{"source":"run","kind":"run","label":"Inviting creators","since":"2026-11-06T07:00:00Z",
                  "step":{"text":"Inviting 40 creators","at":"2026-11-06T07:01:00Z","is_error":false}},
           "waiting":null,"next_check_at":"2026-11-06T10:00:00Z"},
          {"agent":"agent-b","name":"Promotions","role":"promotions","state":"waiting","now":null,
           "waiting":{"code":"approval","label":"Flash deal","since":"2026-11-06T06:00:00Z"},
           "last_run":{"state":"ok","at":"2026-11-06T05:00:00Z"}}
        ]}
        """#
        let activity = #"""
        {"events":[{"at":"2026-11-06T07:00:00Z","text":"line"}],
         "runs":[
           {"run_id":"r1","state":"ok","started_at":"2026-11-06T07:00:00Z","story":{"headline":"Picked creators"}},
           {"run_id":"r2","state":"partial","started_at":"2026-11-06T06:00:00Z"},
           {"run_id":"r3","state":"failed","started_at":"2026-11-06T05:00:00Z"}
         ],
         "drawer":{"runs_48h":55,"ok_48h":37,"partial_48h":17,"failed_48h":1,"drafts_waiting":9,
                   "next_up":{"next_check_at":"2026-11-06T10:00:00Z","drafts_waiting":9}},
         "next_check_at":"2026-11-06T10:00:00Z"}
        """#
        let load = CompanionActivityParser.parse(shopStatus: 200, shopBody: shop, eventBodies: ["agent-a": activity])
        guard case .ready(let agents) = load else { return XCTFail("expected ready") }
        XCTAssertEqual(agents.count, 2)
        let working = agents[0]
        XCTAssertEqual(working.state, "working")
        XCTAssertEqual(OllieActivityNode(agent: working).title, "Creator manager")
        XCTAssertEqual(working.lastRunSummary, "Picked creators")
        XCTAssertEqual(working.sparkline, [.ok, .partial, .failed])
        XCTAssertEqual(working.runs48h, 55)
        XCTAssertEqual(working.ok48h, 37)
        XCTAssertEqual(working.partial48h, 17)
        XCTAssertEqual(working.failed48h, 1)
        XCTAssertEqual(working.draftsWaiting, 9)
        let node = OllieActivityNode(agent: working)
        XCTAssertEqual(node.tone, .blue)
        XCTAssertEqual(node.pill, "Working")
        XCTAssertTrue(node.countsText?.contains("55 runs / 48h") == true)
        XCTAssertEqual(OllieActivityNode(agent: agents[1]).tone, .amber)
        XCTAssertEqual(OllieActivityNode(agent: agents[1]).pill, "Waiting")
        XCTAssertTrue(OllieActivityModel.summary(agents: agents, lastRead: Date()).contains("2 agents · 1 working"))
    }

    func testApprovalsDoThisFirstBatchesOlderAndCategories() throws {
        let json = #"""
        {"counts":{"pending":4,"mine":4},"order":["a","b","c","d"],"shops":[
          {"resource":"north","name":"North Studio","services":[
            {"label":"Promotions","items":[
              {"id":"a","question":"Raise discount","kind":"money","source":"agent_ask","age_seconds":3600,
               "status_reason":"On 3 products","expires_at":null,"can_answer":true,"answers":["approve","skip"],
               "priority":{"band":"now"}},
              {"id":"b","question":"Send sample to Jess","kind":"creator_sample","source":"send_approval","age_seconds":7200,"can_answer":true,"answers":["approve","skip"]},
              {"id":"c","question":"Send sample to Kai","kind":"creator_sample","source":"send_approval","age_seconds":7300,"can_answer":true,"answers":["approve","skip"]},
              {"id":"d","question":"Set weekly budget","kind":"money","source":"send_approval","age_seconds":2678400,
               "expires_at":"2026-01-01T00:00:00Z","can_answer":true,"answers":["approve","skip"]}
            ]}
          ]}
        ]}
        """#
        let list = try JSONDecoder().decode(CompanionApprovalsList.self, from: Data(json.utf8))
        let snapshot = CompanionTodos.make(from: list)
        let model = OllieApprovalsModel(snapshot: snapshot, shopResource: "north")
        XCTAssertEqual(model.doThisFirst?.id, "a")
        XCTAssertEqual(model.batches.count, 1)
        XCTAssertEqual(model.batches[0].items.map(\.id), ["b", "c"])
        XCTAssertEqual(model.batches[0].label, "2 · Promotions")
        XCTAssertEqual(model.older.map(\.id), ["d"])
        XCTAssertEqual(model.newer.map(\.id), [])
        XCTAssertEqual(model.categories.map(\.label), ["Promotions"])
        let old = try XCTUnwrap(model.older.first)
        XCTAssertTrue(OllieApprovalsModel.removedWithinDay(old))

    }

    func testAllShopProgressWithNoElapsedMonthHasNoFakeTick() {
        let totals = CompanionPaceTotals(
            byCurrency: [CompanionPaceCurrencyTotal(currency: "USD", mtd: 100, goal: 1000)],
            behind: 0, unavailableShops: 0, elapsedPct: nil)
        let model = OllieTodayModel(pace: [:], paceState: .available, snapshot: nil,
                                    activity: [:], totals: totals)
        XCTAssertEqual(model.allProgress.first?.pace.expectedByToday, nil)
        XCTAssertEqual(model.allProgress.first?.bar.expectedFraction, nil)
        XCTAssertNil(model.allProgress.first?.pill)
    }

}
