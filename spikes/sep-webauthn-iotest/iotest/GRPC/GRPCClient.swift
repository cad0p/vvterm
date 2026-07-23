// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  GRPCClient.swift
//  iotest
//
//  Session 1.10 — the platform-independent gRPC core (HTTP/2 framing,
//  gRPC unary handler, message framing).
//
//  Architecture:
//    NWConnection (TLS+ALPN+client cert via Network.framework / NIOTS)
//      → NIOHTTP2 frame pipeline
//        → per-stream HTTP2FramePayloadToHTTP1ClientCodec
//          → gRPC unary handler (HEADERS + DATA → HEADERS + DATA + trailers)
//
//  This file is platform-independent (compiles on Linux for testing + on
//  iOS/macOS). The TLS+ALPN+mTLS transport is in GRPCTransport.swift
//  (Apple-only, requires Network + Security frameworks).
//
//  Proven against a local NIOHTTP2 server in the session 1.10 test package
//  (full unary round-trip: HEADERS+DATA → HEADERS+DATA+grpc-status:0).
//

import NIOCore
import NIOHTTP1
import NIOHTTP2
import SwiftProtobuf
import Foundation

// MARK: - Errors

enum GRPCError: Error, CustomStringConvertible {
    case transport(String)
    case tls(String)
    case http2(String)
    case grpc(status: Int, message: String)
    case decode(String)
    case timeout

    var description: String {
        switch self {
        case .transport(let m):   return "transport: \(m)"
        case .tls(let m):         return "tls: \(m)"
        case .http2(let m):       return "http2: \(m)"
        case .grpc(let s, let m): return "grpc(\(s)): \(m)"
        case .decode(let m):      return "decode: \(m)"
        case .timeout:            return "timeout"
        }
    }
}

// MARK: - gRPC unary response handler

/// Accumulates a single gRPC unary response, then resolves a promise.
///
/// Inbound: HTTPClientResponsePart (head/body/end) from
/// HTTP2FramePayloadToHTTP1ClientCodec.
final class GRPCUnaryHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<Data>
    private var body = Data()
    private var trailers = HTTPHeaders()
    private var headers = HTTPHeaders()
    private var resolved = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !resolved else { return }
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            headers = head.headers
        case .body(let buffer):
            body.append(contentsOf: buffer.readableBytesView)
        case .end(let head):
            if let head = head {
                trailers = head
            }
            resolved = true
            let statusStr = trailers.first(name: "grpc-status")
                ?? headers.first(name: "grpc-status")
            if let statusStr, statusStr != "0" {
                let message = trailers.first(name: "grpc-message") ?? ""
                promise.fail(GRPCError.grpc(
                    status: Int(statusStr) ?? -1, message: message))
            } else {
                promise.succeed(body)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !resolved else { return }
        resolved = true
        promise.fail(GRPCError.http2(error.localizedDescription))
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !resolved else { return }
        resolved = true
        promise.fail(GRPCError.transport("stream closed before response end"))
    }
}

// MARK: - gRPC message framing

/// Encode a gRPC unary message frame: 1-byte flag (0=uncompressed) +
/// 4-byte big-endian length + protobuf payload.
func grpcEncodeFrame(_ proto: Data) -> Data {
    var frame = Data(capacity: 5 + proto.count)
    frame.append(0)  // not compressed
    let len = UInt32(proto.count).bigEndian
    withUnsafeBytes(of: len) { frame.append(contentsOf: $0) }
    frame.append(proto)
    return frame
}

/// Decode a gRPC unary message frame: 1-byte flag + 4-byte BE length + proto.
/// Returns (compressed flag, protobuf payload).
func grpcDecodeFrame(_ frame: Data) throws -> (compressed: Bool, proto: Data) {
    guard frame.count >= 5 else {
        throw GRPCError.decode("frame too short: \(frame.count) bytes")
    }
    let compressed = frame[0] != 0
    let msgLen = Int(UInt32(frame[1]) << 24
                     | UInt32(frame[2]) << 16
                     | UInt32(frame[3]) << 8
                     | UInt32(frame[4]))
    guard frame.count >= 5 + msgLen else {
        throw GRPCError.decode("frame truncated: have \(frame.count), need \(5 + msgLen)")
    }
    return (compressed, frame.subdata(in: 5..<(5 + msgLen)))
}

// MARK: - HTTP/2 stream request helper

/// Send a gRPC unary request on a freshly-created HTTP/2 stream channel.
///
/// - Parameters:
///   - multiplexer: the connection's stream multiplexer
///   - path: the gRPC method path, e.g. "/proto.AuthService/CreateRegisterChallenge"
///   - authority: the :authority header value (e.g. "teleport.pcad.it")
///   - request: the protobuf request message
/// - Returns: the raw gRPC response frame bytes (pre-decode)
func grpcUnaryCall<R: SwiftProtobuf.Message>(
    multiplexer: NIOHTTP2Handler.StreamMultiplexer,
    path: String,
    authority: String,
    request: R
) async throws -> Data {
    let frame = grpcEncodeFrame(try request.serializedData())

    // Create a new stream channel with the HTTP/1-style codec + unary handler.
    let streamChannel = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Channel, Error>) in
        multiplexer.createStreamChannel(promise: nil) { streamChannel in
            let p = streamChannel.eventLoop.makePromise(of: Void.self)
            p.succeed(())
            cont.resume(returning: streamChannel)
            return p.futureResult
        }
    }

    // Add the codec + response handler to the stream pipeline.
    let codec = HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
    let promise = streamChannel.eventLoop.makePromise(of: Data.self)
    try await streamChannel.pipeline.addHandler(codec).get()
    try await streamChannel.pipeline.addHandler(GRPCUnaryHandler(promise: promise)).get()

    // Build + send the request HEADERS + body + END.
    // The HTTP2FramePayloadToHTTP1ClientCodec builds the HTTP/2 pseudo-headers
    // (:method, :path, :scheme, :authority) from the HTTPRequestHead + a
    // "host" header. We must NOT send pseudo-headers ourselves (that causes
    // DuplicatePseudoHeader). Send only regular HTTP headers.
    var headers = HTTPHeaders()
    headers.add(name: "host", value: authority)
    headers.add(name: "content-type", value: "application/grpc")
    headers.add(name: "te", value: "trailers")
    headers.add(name: "grpc-timeout", value: "60S")
    headers.add(name: "user-agent", value: "vvterm-1.10-spike")
    let head = HTTPRequestHead(version: .http2, method: .POST, uri: path, headers: headers)

    let allocator = streamChannel.allocator
    streamChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
    var bodyBuffer = allocator.buffer(capacity: frame.count)
    bodyBuffer.writeBytes(frame)
    streamChannel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(bodyBuffer))), promise: nil)
    streamChannel.write(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)
    streamChannel.flush()

    // Await the response body.
    let respBody = try await promise.futureResult.get()
    return respBody
}

/// Convenience: make a typed unary call and decode the response protobuf.
func grpcUnaryCallTyped<R: SwiftProtobuf.Message, S: SwiftProtobuf.Message>(
    multiplexer: NIOHTTP2Handler.StreamMultiplexer,
    path: String,
    authority: String,
    request: R,
    responseType: S.Type
) async throws -> S {
    let frame = try await grpcUnaryCall(
        multiplexer: multiplexer, path: path, authority: authority, request: request
    )
    let (_, proto) = try grpcDecodeFrame(frame)
    return try S(serializedBytes: proto)
}

// MARK: - Timeout helper

func withTimeout<T>(_ future: EventLoopFuture<T>, seconds: Int64) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await future.get()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw GRPCError.timeout
        }
        guard let result = try await group.next() else {
            throw GRPCError.timeout
        }
        group.cancelAll()
        return result
    }
}
