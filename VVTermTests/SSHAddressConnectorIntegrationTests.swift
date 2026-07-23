import Darwin
import Foundation
import Testing
@testable import VVTerm

struct SSHAddressConnectorIntegrationTests {
    @Test
    func unreachableFirstAddressDoesNotBlockReachableFallback() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let unreachableHost = ProcessInfo.processInfo.environment["VVTERM_UNREACHABLE_TEST_HOST"]
            ?? "192.168.101.253"
        let unreachable = try SSHAddressConnector.resolvedCandidates(
            host: unreachableHost,
            port: listener.port
        )
        let reachable = try SSHAddressConnector.resolvedCandidates(
            host: "127.0.0.1",
            port: listener.port
        )
        let startedAt = ContinuousClock.now

        let descriptor = try await SSHAddressConnector.connect(
            candidates: unreachable + reachable,
            trace: nil,
            timeout: .seconds(2)
        )
        Darwin.close(descriptor)

        #expect(startedAt.duration(to: .now) < .seconds(1))
    }

    @Test
    func addressConnectionStopsPromptlyWhenCancelled() async throws {
        let unreachableHost = ProcessInfo.processInfo.environment["VVTERM_UNREACHABLE_TEST_HOST"]
            ?? "192.168.101.253"
        let resolvedCandidates = try SSHAddressConnector.resolvedCandidates(
            host: unreachableHost,
            port: 65_000
        )
        var gateContinuation: AsyncStream<Void>.Continuation?
        let gate = AsyncStream<Void> { gateContinuation = $0 }
        let task = Task {
            for await _ in gate { break }
            return try await SSHAddressConnector.connect(
                candidates: resolvedCandidates,
                trace: nil,
                timeout: .seconds(5)
            )
        }
        let cancellationStartedAt = ContinuousClock.now
        task.cancel()
        gateContinuation?.finish()

        do {
            let descriptor = try await task.value
            Darwin.close(descriptor)
            Issue.record("Unreachable candidate unexpectedly connected")
        } catch is CancellationError {
            #expect(cancellationStartedAt.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Expected cancellation, received: \(error)")
        }
    }
}

private final class LoopbackListener {
    private(set) var descriptor: Int32 = -1
    private(set) var port: Int = 0

    init() throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            close()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }
}
