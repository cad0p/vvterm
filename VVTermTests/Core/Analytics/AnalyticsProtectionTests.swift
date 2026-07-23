import Foundation
import Testing
import Umami
@testable import VVTerm

@Suite
struct AnalyticsEnvironmentPolicyTests {
    @Test(arguments: [
        (false, false, false, false, false, true),
        (true, true, false, false, false, true),
        (true, false, true, false, false, true),
        (true, false, false, true, false, true),
        (true, false, false, false, true, true),
        (true, false, false, false, false, false)
    ])
    func nonProductionContextsAreDisabled(
        userEnabled: Bool,
        isDevelopmentBuild: Bool,
        isSimulator: Bool,
        isPreview: Bool,
        isRunningTests: Bool,
        isVerifiedProductionInstall: Bool
    ) {
        #expect(AnalyticsEnvironmentPolicy.mode(
            userEnabled: userEnabled,
            isDevelopmentBuild: isDevelopmentBuild,
            isSimulator: isSimulator,
            isPreview: isPreview,
            isRunningTests: isRunningTests,
            isVerifiedProductionInstall: isVerifiedProductionInstall
        ) == .disabled)
    }

    @Test
    func verifiedProductionInstallIsTheOnlyProductionContext() {
        #expect(AnalyticsEnvironmentPolicy.mode(
            userEnabled: true,
            isDevelopmentBuild: false,
            isSimulator: false,
            isPreview: false,
            isRunningTests: false,
            isVerifiedProductionInstall: true
        ) == .production)
    }
}

@Suite
struct AnalyticsEventTests {
    @Test
    func eventNamesAndSchemasComeFromTheClosedEventSet() {
        let event = AnalyticsEvent.purchaseFailed(
            source: String(repeating: "s", count: 200),
            productID: String(repeating: "p", count: 200),
            reason: String(repeating: "r", count: 200)
        )
        let definition = event.definition

        #expect(definition.name == "purchase_failed")
        #expect(definition.url == "/app/paywall")
        #expect(definition.data.count == 3)
        #expect(definition.data["source"] == .string(String(repeating: "s", count: 128)))
        #expect(definition.data["product"] == .string(String(repeating: "p", count: 128)))
        #expect(definition.data["reason"] == .string(String(repeating: "r", count: 128)))
    }

    @Test
    func countsAreClampedToTheirDocumentedBounds() {
        let definition = AnalyticsEvent.limitHit(
            source: "server_limit",
            generation: "current",
            current: .max,
            limit: .min
        ).definition

        #expect(definition.name == "limit_hit")
        #expect(definition.data["current"] == .integer(1_000_000))
        #expect(definition.data["limit"] == .integer(0))
    }

    @Test
    @MainActor
    func enrichmentFiltersUnknownAndMalformedAttribution() {
        let payload = AnalyticsTracker.enrichedPayload(
            ["source": .string("settings")],
            attribution: [
                "apple_ads_campaign_id": .string(String(repeating: "1", count: 200)),
                "is_apple_ads_attributed": .string("not-a-bool"),
                "unknown": .string("drop-me")
            ]
        )

        #expect(payload["apple_ads_campaign_id"] == .string(String(repeating: "1", count: 128)))
        #expect(payload["is_apple_ads_attributed"] == nil)
        #expect(payload["unknown"] == nil)
        #expect(payload["platform"] != nil)
        #expect(payload["version"] != nil)
        #expect(payload["build"] != nil)
    }
}

@Suite
struct AnalyticsAdmissionControllerTests {
    @Test
    func duplicateEventsAreRejectedWithinTwoSeconds() {
        var admission = AnalyticsAdmissionController()
        let event = AnalyticsEvent.welcomeCompleted

        let first = admission.admits(event, at: 10)
        let duplicate = admission.admits(event, at: 11.999)
        let afterDeduplicationWindow = admission.admits(event, at: 12)
        #expect(first)
        #expect(!duplicate)
        #expect(afterDeduplicationWindow)
    }

    @Test
    func repeatedProcessLaunchesAreSuppressedForFiveMinutes() {
        #expect(!AnalyticsAdmissionController.admitsPersistentLaunch(
            lastEmission: 100,
            at: 399.999,
            minimumInterval: 300
        ))
        #expect(AnalyticsAdmissionController.admitsPersistentLaunch(
            lastEmission: 100,
            at: 400,
            minimumInterval: 300
        ))
        #expect(AnalyticsAdmissionController.admitsPersistentLaunch(
            lastEmission: 100,
            at: 90,
            minimumInterval: 300
        ))
    }

    @Test
    func eachEventNameIsLimitedWithinTheWindow() {
        var admission = AnalyticsAdmissionController()

        for index in 0..<AnalyticsAdmissionController.maximumEventsPerNamePerWindow {
            let admitted = admission.admits(
                .connectionFailed(transport: "ssh", reason: "reason-\(index)"),
                at: Double(index * 3)
            )
            #expect(admitted)
        }
        let overLimit = admission.admits(
            .connectionFailed(transport: "mosh", reason: "another"),
            at: 30
        )
        #expect(!overLimit)
    }

    @Test
    func theTotalWindowIsBoundedAndResetsWithoutCounterOverflow() {
        var admission = AnalyticsAdmissionController()

        for index in 0..<AnalyticsAdmissionController.maximumEventsPerWindow {
            let value = "value-\(index)"
            let event = switch index % 10 {
            case 0: AnalyticsEvent.connectionFailed(transport: value, reason: value)
            case 1: AnalyticsEvent.paywallViewed(source: value)
            case 2: AnalyticsEvent.paywallCTATapped(source: value, productID: value)
            case 3: AnalyticsEvent.purchaseStarted(source: value, productID: value)
            case 4: AnalyticsEvent.purchaseSucceeded(source: value, productID: value)
            case 5: AnalyticsEvent.purchaseCancelled(source: value, productID: value)
            case 6: AnalyticsEvent.purchasePending(source: value, productID: value)
            case 7: AnalyticsEvent.purchaseFailed(source: value, productID: value, reason: value)
            case 8: AnalyticsEvent.limitHit(source: value, generation: value, current: index, limit: 1)
            default: AnalyticsEvent.freePlanGenerationAssigned(
                generation: value,
                serverCount: index,
                reason: value
            )
            }
            let admitted = admission.admits(event, at: Double(index) * 0.9)
            #expect(admitted)
        }

        let overTotalLimit = admission.admits(.paywallViewed(source: "settings"), at: 55)
        let afterWindowReset = admission.admits(.paywallViewed(source: "settings"), at: 60)
        let afterClockReset = admission.admits(.welcomeCompleted, at: 1)
        #expect(!overTotalLimit)
        #expect(afterWindowReset)
        #expect(afterClockReset)
    }
}

private actor BlockingAnalyticsDelivery {
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func send(_ event: TrackEventRequest) async {
        callCount += 1
        guard callCount == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isBlocked() -> Bool {
        continuation != nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func calls() -> Int {
        callCount
    }
}

@Suite
struct AnalyticsDeliveryQueueTests {
    @Test
    func pendingDeliveryIsBounded() async {
        let delivery = BlockingAnalyticsDelivery()
        let queue = AnalyticsDeliveryQueue(capacity: 2) { event in
            await delivery.send(event)
        }
        let event = TrackEventRequest(source: .website("test"), name: "test")

        let first = Task { await queue.enqueue(event) }
        for _ in 0..<100 where !(await delivery.isBlocked()) {
            await Task.yield()
        }
        #expect(await delivery.isBlocked())
        #expect(await queue.enqueue(event))
        #expect(await queue.enqueue(event))
        #expect(!(await queue.enqueue(event)))
        #expect(await queue.pendingCount() == 2)

        await delivery.release()
        #expect(await first.value)
        #expect(await delivery.calls() == 3)
        #expect(await queue.pendingCount() == 0)
    }
}
