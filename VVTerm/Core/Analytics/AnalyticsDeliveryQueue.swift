import Foundation
import Umami

actor AnalyticsProductionTransport {
    private static let endpoint = URL(string: "https://analytics.vivy.app")!
    private var client: UmamiTrackerClient?

    func send(_ event: TrackEventRequest) async {
        let client: UmamiTrackerClient
        if let existingClient = self.client {
            client = existingClient
        } else {
            let newClient = UmamiTrackerClient(configuration: .init(baseURL: Self.endpoint))
            self.client = newClient
            client = newClient
        }
        _ = try? await client.track(event)
    }
}

actor AnalyticsDeliveryQueue {
    typealias Delivery = @Sendable (TrackEventRequest) async -> Void

    static let defaultCapacity = 32

    private let capacity: Int
    private let delivery: Delivery
    private var pending: [TrackEventRequest] = []
    private var isDraining = false

    init(capacity: Int = defaultCapacity, delivery: @escaping Delivery) {
        self.capacity = max(1, capacity)
        self.delivery = delivery
    }

    @discardableResult
    func enqueue(_ event: TrackEventRequest) async -> Bool {
        guard pending.count < capacity else { return false }
        pending.append(event)
        guard !isDraining else { return true }

        isDraining = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            await delivery(next)
        }
        isDraining = false
        return true
    }

    func pendingCount() -> Int {
        pending.count
    }
}
