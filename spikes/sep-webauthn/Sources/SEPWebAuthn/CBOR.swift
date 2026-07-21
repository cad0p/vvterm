// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  CBOR.swift
//  SEPWebAuthn
//
//  Minimal canonical CTAP2 CBOR encoder for the SEP-WebAuthn spike.
//
//  We need exactly four CBOR shapes:
//
//    1. The COSE EC2 public key (a map with integer keys 1, 3, -1, -2, -3).
//       (see coseEC2PublicKeyCBOR in Attestation.swift)
//
//    2. The `packed` attestation object — a map with STRING keys:
//         { "fmt": "packed", "attStmt": { "alg": -7, "sig": <bytes> },
//           "authData": <bytes> }
//
//  The Go path uses fxamacker/cbor with default options, which produces
//  canonical CTAP2 CBOR:
//    - map keys sorted by encoded-byte length first, then bytewise
//    - integers use the smallest possible encoding
//    - byte strings (major type 2) for `bstr`
//    - text strings (major type 3) for `tstr`
//
//  This file implements exactly enough to encode those shapes canonically.
//  It is NOT a general CBOR encoder — do not use it for other purposes without
//  verifying the output against a reference encoder.

import Foundation

public enum CBOR {
    // MARK: - Head encoders

    /// Encode an unsigned integer in the smallest CBOR form.
    public static func encodeUint(_ value: UInt64) -> Data {
        return encodeHead(majorType: 0, argument: value)
    }

    /// Encode a signed integer. Uses the smallest form: small negatives
    /// (−1..−24) become a single-byte head (major type 1, arg 0..23);
    /// larger negatives use the smallest additional-byte form.
    public static func encodeInt(_ value: Int64) -> Data {
        if value >= 0 {
            return encodeHead(majorType: 0, argument: UInt64(value))
        } else {
            // CBOR negative: −1 − value, stored as major type 1.
            // For value = -1 → arg 0 → 0x20. For -7 → arg 6 → 0x26. For
            // -100 → arg 99 → 0x38 0x63. Etc.
            let arg = UInt64(-(value + 1))  // = (-value) - 1
            return encodeHead(majorType: 1, argument: arg)
        }
    }

    private static func encodeHead(majorType: UInt8, argument: UInt64) -> Data {
        // Initial byte: (majorType << 5) | additionalInfo
        // additionalInfo: 0..23 → inline, 24 → 1 byte follows, 25 → 2, 26 → 4, 27 → 8
        let mt = (majorType & 0x07) << 5
        if argument < 24 {
            return Data([mt | UInt8(argument)])
        } else if argument <= UInt64(UInt8.max) {
            return Data([mt | 24, UInt8(argument)])
        } else if argument <= UInt64(UInt16.max) {
            let be = UInt16(argument).bigEndianBytes
            return Data([mt | 25] + be)
        } else if argument <= UInt64(UInt32.max) {
            let be = UInt32(argument).bigEndianBytes
            return Data([mt | 26] + be)
        } else {
            let be = argument.bigEndianBytes
            return Data([mt | 27] + be)
        }
    }

    // MARK: - Value encoders

    /// Encode a byte string (CBOR major type 2).
    public static func encodeByteString(_ data: Data) -> Data {
        return encodeHead(majorType: 2, argument: UInt64(data.count)) + data
    }

    /// Encode a UTF-8 text string (CBOR major type 3).
    public static func encodeString(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        return encodeHead(majorType: 3, argument: UInt64(utf8.count)) + utf8
    }

    /// Encode `true` (0xF5) or `false` (0xF4). CTAP2 canonical form uses
    /// major type 7, simplified bool. (Not used in the packed format, but
    /// included for completeness if `attStmt` ever carries bools.)
    public static func encodeBool(_ b: Bool) -> Data {
        return Data([b ? 0xF5 : 0xF4])
    }

    // MARK: - Map encoders

    /// Encode a map from pre-encoded key bytes to pre-encoded value bytes.
    ///
    /// CTAP2 canonical CBOR requires map keys to be sorted in the
    /// "length-first, then bytewise lexicographic" order of their CBOR
    /// encodings. This function sorts the provided `(keyBytes, valueBytes)`
    /// pairs by key bytes accordingly and emits the map.
    ///
    /// Callers must pre-encode keys and values with `encodeInt`,
    /// `encodeString`, `encodeByteString`, etc.
    public static func encodeMap(items: [(Data, Data)]) -> Data {
        let sorted = items.sorted { lhs, rhs in
            // Length-first, then bytewise lexicographic. This matches
            // fxamacker/cbor's default canonical ordering (CanonicalCBORMode
            // = LengthFirst).
            if lhs.0.count != rhs.0.count {
                return lhs.0.count < rhs.0.count
            }
            return lhs.0.lexicographicallyPrecedes(rhs.0)
        }
        var out = encodeHead(majorType: 5, argument: UInt64(sorted.count))
        for (k, v) in sorted {
            out.append(k)
            out.append(v)
        }
        return out
    }
}

// MARK: - base64url helpers (no padding)

extension Data {
    /// base64url without padding — mirrors Go's base64.RawURLEncoding.
    func base64URLEncodedString() -> String {
        var s = self.base64EncodedString()
        // base64 → base64url: replace + with -, / with _, strip padding.
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// base64url decode (tolerates padding but doesn't require it).
    init?(base64URLEncoded string: String) {
        var s = string
        s = s.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4.
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}

// MARK: - FixedWidthValue big-endian byte helpers

private protocol BigEndianBytes {
    var bigEndianBytes: [UInt8] { get }
}

extension UInt16: BigEndianBytes {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return [UInt8(truncatingIfNeeded: be >> 8),
                UInt8(truncatingIfNeeded: be & 0xff)]
    }
}

extension UInt32: BigEndianBytes {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return [
            UInt8(truncatingIfNeeded: be >> 24),
            UInt8(truncatingIfNeeded: be >> 16),
            UInt8(truncatingIfNeeded: be >> 8),
            UInt8(truncatingIfNeeded: be & 0xff),
        ]
    }
}

extension UInt64: BigEndianBytes {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        var out: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: be >> shift))
        }
        return out
    }
}
