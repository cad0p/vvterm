// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  main.swift
//  sep-spike-cli
//
//  Drives the SEP-WebAuthn spike end-to-end against a Teleport proxy.
//
//  Steps (mirrors the session prompt's Part A/B test plan):
//    1. POST /webapi/mfa/token/:token/registerchallenge
//       → CredentialCreation challenge (with challenge bytes + rpId + user)
//    2. WebAuthn.register(...) → packed attestation
//    3. POST /webapi/mfa/devices → device registered
//    4. POST /webapi/mfa/login/begin {"passwordless": true}
//       → CredentialAssertion challenge
//    5. WebAuthn.login(...) → assertion
//    6. Generate ed25519 SSH keypair + TLS cert CSR
//    7. POST /webapi/mfa/login/finish with assertion + pub_keys + ttl
//       → SSH cert in the response body
//
//  Exit code 0 on success (cert returned), non-zero on any failure.
//  Prints each step's request/response for debugging.

import Foundation
import SEPWebAuthn

// MARK: - Argument parsing

struct CLIArgs {
    let token: String
    let host: String
    let signerKind: SignerKind
    let ttl: Int           // seconds
    let deviceName: String
    let insecure: Bool
    let biometry: Bool     // SEP signer only — gate SecKey with .biometryAny
}

enum SignerKind: String {
    case software
    case sep
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case missingEnv(String)
    case http(status: Int, body: String)
    case decode(String)
    case noCert

    var description: String {
        switch self {
        case .usage(let m):           return "usage: \(m)"
        case .missingEnv(let n):      return "missing env var: \(n)"
        case .http(let s, let b):     return "HTTP \(s): \(b)"
        case .decode(let m):          return "decode: \(m)"
        case .noCert:                 return "no cert in response"
        }
    }
}

func parseArgs() throws -> CLIArgs {
    var token: String?
    var host = "teleport.pcad.it"
    var signer: SignerKind = .software
    var ttl = 3600  // 1h
    var deviceName = "vvterm-sep-spike"
    var insecure = false
    var biometry = false

    let args = CommandLine.arguments.dropFirst()
    var iter = args.makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--token":
            token = iter.next()
        case "--host":
            host = iter.next() ?? host
        case "--signer":
            let s = iter.next() ?? ""
            guard let kind = SignerKind(rawValue: s) else {
                throw CLIError.usage("unknown --signer \(s) (software|sep)")
            }
            signer = kind
        case "--ttl":
            ttl = Int(iter.next() ?? "") ?? ttl
        case "--device-name":
            deviceName = iter.next() ?? deviceName
        case "--insecure":
            insecure = true
        case "--biometry":
            // SEP signer only (Part C / session 1.6b). Creates the SEP key
            // with .biometryAny so SecKeyCreateSignature blocks until Touch
            // ID / Face ID is presented. Requires a real biometric sensor —
            // will block forever on the headless macos-14 runner. Run on a
            // Touch-ID Mac (1.6b Option B) or an iOS device (1.6b Option A).
            biometry = true
        case "-h", "--help":
            print("""
            sep-spike-cli — SEP-WebAuthn spike driver

            Usage:
              sep-spike-cli --token <invite-token> [options]

            Options:
              --token <t>        Invite token from `tctl users add` (required)
              --host <h>         Teleport proxy host (default: teleport.pcad.it)
              --signer <s>       software | sep  (default: software)
              --ttl <secs>       Cert TTL in seconds (default: 3600)
              --device-name <n>  MFA device name (default: vvterm-sep-spike)
              --insecure         Skip TLS verification (dev clusters)
              --biometry         SEP only: gate key with .biometryAny (Touch/Face ID)
                                 Requires a real biometric sensor; blocks on sign.
                                 Session 1.6b (Part C). Ignored for --signer software.
              -h, --help         Show this help
            """)
            exit(0)
        default:
            throw CLIError.usage("unknown argument: \(arg)")
        }
    }

    // Token can come from arg or env (CI secret → env).
    if token == nil {
        token = ProcessInfo.processInfo.environment["INVITE_TOKEN"]
    }
    guard let token, !token.isEmpty else {
        throw CLIError.usage("--token required (or INVITE_TOKEN env var)")
    }
    return CLIArgs(
        token: token, host: host, signerKind: signer,
        ttl: ttl, deviceName: deviceName, insecure: insecure,
        biometry: biometry
    )
}

// MARK: - HTTP client

final class TeleportClient {
    let baseURL: URL
    let session: URLSession

    init(host: String, insecure: Bool) {
        self.baseURL = URL(string: "https://\(host)")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        if insecure {
            // Allow self-signed certs for dev clusters. The spike doesn't
            // ship this path to production — it's a dev convenience.
            config.httpAdditionalHeaders = [:]
            self.session = URLSession(
                configuration: config,
                delegate: InsecureTLSDelegate(),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: config)
        }
    }

    func postJSON<T: Decodable>(
        path: String,
        body: Data,
        as type: T.Type
    ) throws -> (status: Int, body: Data, decoded: T?) {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try session.synchronousDataTask(with: req)
        let http = response as! HTTPURLResponse
        let decoded = try? JSONDecoder().decode(T.self, from: data)
        return (http.statusCode, data, decoded)
    }

    func postJSONEncodable<E: Encodable, D: Decodable>(
        path: String,
        body: E,
        as type: D.Type
    ) throws -> (status: Int, body: Data, decoded: D?) {
        let json = try JSONEncoder().encode(body)
        return try postJSON(path: path, body: json, as: type)
    }

    func putJSONEncodable<E: Encodable, D: Decodable>(
        path: String,
        body: E,
        as type: D.Type
    ) throws -> (status: Int, body: Data, decoded: D?) {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try session.synchronousDataTask(with: req)
        let http = response as! HTTPURLResponse
        let decoded = try? JSONDecoder().decode(D.self, from: data)
        return (http.statusCode, data, decoded)
    }
}

final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
    }
}

extension URLSession {
    func synchronousDataTask(with req: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>!
        let sem = DispatchSemaphore(value: 0)
        self.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success((data ?? Data(), response!)) }
            sem.signal()
        }.resume()
        sem.wait()
        switch result! {
        case .failure(let e): throw e
        case .success(let r): return r
        }
    }
}

// MARK: - Teleport wire types (decoded responses)

struct RegisterChallengeResponse: Decodable {
    // { "webauthn": { "publicKey": { "challenge": "...", "rp": {"id": "...", "name": "..."},
    //   "user": {"name": "...", "displayName": "...", "id": "..."}, ... } } }
    let webauthn: WebauthnCC?
    struct WebauthnCC: Decodable {
        let publicKey: PublicKey
        struct PublicKey: Decodable {
            let challenge: String  // base64url
            let rp: RP
            struct RP: Decodable { let id: String; let name: String }
            let user: User
            struct User: Decodable {
                let name: String; let displayName: String; let id: String
            }
        }
    }
}


struct LoginBeginResponse: Decodable {
    // { "webauthn_challenge": { "publicKey": { "challenge": "...", "rpId": "..." } } }
    let webauthnChallenge: WebauthnAssertion?
    enum CodingKeys: String, CodingKey {
        case webauthnChallenge = "webauthn_challenge"
    }
    struct WebauthnAssertion: Decodable {
        let publicKey: PublicKey
        struct PublicKey: Decodable {
            let challenge: String  // base64url
            let rpId: String?
            enum CodingKeys: String, CodingKey {
                case challenge
                case rpId = "rpId"
            }
        }
    }
}

struct LoginFinishResponse: Decodable {
    // { "cert": "base64 ssh cert", "host_signers": [...] }
    let cert: String?
    let hostSigners: [HostSigner]?
    enum CodingKeys: String, CodingKey {
        case cert
        case hostSigners = "host_signers"
    }
    struct HostSigner: Decodable {
        let domainName: String
        let checkingKeys: [String]
        enum CodingKeys: String, CodingKey {
            case domainName = "domain_name"
            case checkingKeys = "checking_keys"
        }
    }
}

// MARK: - SSH keypair generation

func generateSSHPubKey() throws -> String {
    // Use Process to call `ssh-keygen` — universally available on macOS
    // runners, avoids depending on a Swift SSH library. Generates an
    // ed25519 keypair, returns the .pub content (authorized_keys format),
    // which is what AuthenticateSSHUserRequest.ssh_pub_key expects.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sep-spike-\(UUID().uuidString)"
    )
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    proc.arguments = [
        "-t", "ed25519",
        "-N", "",
        "-f", tmp.path,
        "-C", "sep-spike",
    ]
    let pipe = Pipe()
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CLIError.decode("ssh-keygen failed: \(err)")
    }
    let pub = try String(contentsOf: URL(fileURLWithPath: tmp.path + ".pub"))
    // Stash the private key path for potential follow-up use (not needed
    // for the spike — we only POST the pub key).
    return pub.trimmingCharacters(in: .whitespacesAndNewlines)
}

func generateTLSPubKey() -> String {
    // For the spike, send an empty TLS pub key. AuthenticateSSHUserRequest
    // requires EITHER ssh_pub_key OR tls_pub_key; we send ssh_pub_key only.
    // (tls_pub_key would be needed for gRPC / TLS-based sessions; session 3
    // territory.)
    return ""
}

// MARK: - Main

func main() {
    do {
        let args = try parseArgs()
        try runSpike(args: args)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

func runSpike(args: CLIArgs) throws {
    let signer: WebAuthnSigner
    switch args.signerKind {
    case .software: signer = SoftwareSigner()
    case .sep:
        if args.biometry {
            signer = SecureEnclaveSigner(biometry: true)
        } else {
            signer = SecureEnclaveSigner()
        }
    }

    print("=== SEP-WebAuthn spike ===")
    print("host:    \(args.host)")
    print("signer:  \(signer.label)\(args.biometry && args.signerKind == .sep ? " +biometry" : "")")
    print("ttl:     \(args.ttl)s")
    print("device:  \(args.deviceName)")
    print("origin:  https://\(args.host)")
    print("rpID:    \(args.host)")
    print("")

    let client = TeleportClient(host: args.host, insecure: args.insecure)
    let origin = "https://\(args.host)"
    let rpID = args.host

    // ── Step 1: /webapi/mfa/token/:token/registerchallenge ────────────
    print("[1/7] POST /webapi/mfa/token/<token>/registerchallenge")
    let regChalReq: [String: String] = [
        "deviceType": "webauthn",
        "deviceUsage": "passwordless",
    ]
    let regChalBody = try JSONSerialization.data(withJSONObject: regChalReq)
    let regChalPath = "/webapi/mfa/token/\(args.token)/registerchallenge"
    let (rc1Status, rc1Body, rc1) = try client.postJSON(
        path: regChalPath, body: regChalBody,
        as: RegisterChallengeResponse.self
    )
    print("  → HTTP \(rc1Status)")
    guard rc1Status == 200, let rc1, let webauthn = rc1.webauthn else {
        print("  body: \(String(data: rc1Body, encoding: .utf8) ?? "<binary>")")
        throw CLIError.http(status: rc1Status, body: String(data: rc1Body, encoding: .utf8) ?? "")
    }
    let challengeB64url = webauthn.publicKey.challenge
    let serverChallenge = Data(base64URLEncoded: challengeB64url)
        ?? Data(challengeB64url.utf8)
    let userHandle = Data(base64URLEncoded: webauthn.publicKey.user.id)
        ?? Data(webauthn.publicKey.user.id.utf8)
    print("  challenge: \(challengeB64url) (\(serverChallenge.count) bytes)")
    print("  rpId:      \(webauthn.publicKey.rp.id)")
    print("  user.name: \(webauthn.publicKey.user.name)")

    // ── Step 2: create key + build attestation ─────────────────────────
    print("[2/7] signer.createKey() + WebAuthn.register(...)")
    let (credentialID, publicKeyRaw) = try signer.createKey()
    print("  credentialID: \(credentialID.base64URLEncodedString())")
    print("  pubkey raw:   \(publicKeyRaw.count) bytes (0x04 || X || Y)")
    let ccr = try WebAuthn.register(
        origin: origin,
        rpID: rpID,
        challenge: serverChallenge,
        credentialID: credentialID,
        publicKeyRaw: publicKeyRaw,
        signer: signer
    )
    print("  attestationObject: \(ccr.response.attestationObject.prefix(40))...")

    // ── Step 3: PUT /webapi/users/password/token ────────────────────────
    // This is the invite-token device-add endpoint. POST /webapi/mfa/devices
    // is WithAuth (requires a session cookie) and there's no token-path POST
    // for device add — tsh uses gRPC AddMFADeviceSync. The web invite flow
    // uses PUT /webapi/users/password/token (changeUserAuthentication),
    // which takes the invite token + the attestation, registers the FIRST
    // device, AND returns a session (cookie set on the response).
    print("[3/7] PUT /webapi/users/password/token (changeUserAuthentication)")
    struct ChangeUserAuthReq: Encodable {
        // JSON keys MUST match lib/web/apiserver.go changeUserAuthenticationRequest.
        let token: String
        let deviceName: String
        let password: String          // empty — passwordless-only user
        let webauthnCreationResponse: CredentialCreationResponse
        enum CodingKeys: String, CodingKey {
            case token
            case deviceName
            case password
            case webauthnCreationResponse
        }
    }
    let changeReq = ChangeUserAuthReq(
        token: args.token,
        deviceName: args.deviceName,
        password: "",
        webauthnCreationResponse: ccr
    )
    struct ChangedUserAuthn: Decodable {}  // response is {} or has recovery codes; we don't need it
    let (rc3Status, rc3Body, _) = try client.putJSONEncodable(
        path: "/webapi/users/password/token", body: changeReq,
        as: ChangedUserAuthn.self
    )
    print("  → HTTP \(rc3Status)")
    guard rc3Status == 200 else {
        print("  body: \(String(data: rc3Body, encoding: .utf8) ?? "<binary>")")
        throw CLIError.http(status: rc3Status, body: String(data: rc3Body, encoding: .utf8) ?? "")
    }
    print("  ✓ device registered (first passwordless device for pier-vvterm-test)")

    // ── Step 4: /webapi/mfa/login/begin ───────────────────────────────
    print("[4/7] POST /webapi/mfa/login/begin {\"passwordless\": true}")
    let beginReq: [String: Bool] = ["passwordless": true]
    let beginBody = try JSONSerialization.data(withJSONObject: beginReq)
    let (rc4Status, rc4Body, rc4) = try client.postJSON(
        path: "/webapi/mfa/login/begin", body: beginBody,
        as: LoginBeginResponse.self
    )
    print("  → HTTP \(rc4Status)")
    guard rc4Status == 200, let rc4, let assertion = rc4.webauthnChallenge else {
        print("  body: \(String(data: rc4Body, encoding: .utf8) ?? "<binary>")")
        throw CLIError.http(status: rc4Status, body: String(data: rc4Body, encoding: .utf8) ?? "")
    }
    let loginChallengeB64url = assertion.publicKey.challenge
    let loginChallenge = Data(base64URLEncoded: loginChallengeB64url)
        ?? Data(loginChallengeB64url.utf8)
    let loginRpID = assertion.publicKey.rpId ?? rpID
    print("  challenge: \(loginChallengeB64url) (\(loginChallenge.count) bytes)")
    print("  rpId:      \(loginRpID)")

    // ── Step 5: WebAuthn.login(...) ───────────────────────────────────
    print("[5/7] WebAuthn.login(...)")
    let assertionResp = try WebAuthn.login(
        origin: origin,
        rpID: loginRpID,
        challenge: loginChallenge,
        credentialID: credentialID,
        userHandle: userHandle,
        signer: signer
    )
    print("  assertion sig: \(assertionResp.response.signature.prefix(40))...")

    // ── Step 6: generate SSH keypair ───────────────────────────────────
    print("[6/7] ssh-keygen ed25519")
    let sshPubKey = try generateSSHPubKey()
    print("  ssh_pub_key: \(sshPubKey.prefix(60))...")

    // ── Step 7: POST /webapi/mfa/login/finish ──────────────────────────
    print("[7/7] POST /webapi/mfa/login/finish")
    struct LoginFinishReq: Encodable {
        // JSON keys MUST match lib/client/weblogin.go AuthenticateSSHUserRequest.
        // `webauthn_challenge_response` is snake_case (not camelCase).
        // `ttl` is time.Duration → nanoseconds (Int64).
        // `ssh_pub_key` is UserPublicKeys.SSHPubKey which is `[]byte` in Go —
        // Go's encoding/json base64-encodes []byte on marshal and base64-
        // decodes on unmarshal. So the JSON wire value must be base64(
        // authorized_keys_string). Swift's JSONEncoder encodes `Data` as
        // base64, matching Go's []byte behavior.
        let webauthnChallengeResponse: CredentialAssertionResponse
        let sshPubKey: Data  // base64-encoded by JSONEncoder, matching Go []byte
        let ttl: Int64  // nanoseconds — see AuthenticateSSHUserRequest.TTL
        enum CodingKeys: String, CodingKey {
            case webauthnChallengeResponse = "webauthn_challenge_response"
            case sshPubKey = "ssh_pub_key"
            case ttl
        }
    }
    let finishReq = LoginFinishReq(
        webauthnChallengeResponse: assertionResp,
        sshPubKey: Data(sshPubKey.utf8),  // authorized_keys string as bytes → base64-encoded by JSONEncoder
        ttl: Int64(args.ttl) * 1_000_000_000  // seconds → ns
    )
    let (rc7Status, rc7Body, rc7) = try client.postJSONEncodable(
        path: "/webapi/mfa/login/finish", body: finishReq,
        as: LoginFinishResponse.self
    )
    print("  → HTTP \(rc7Status)")
    guard rc7Status == 200 else {
        print("  body: \(String(data: rc7Body, encoding: .utf8) ?? "<binary>")")
        throw CLIError.http(status: rc7Status, body: String(data: rc7Body, encoding: .utf8) ?? "")
    }
    guard let cert = rc7?.cert, !cert.isEmpty else {
        print("  body: \(String(data: rc7Body, encoding: .utf8) ?? "<binary>")")
        throw CLIError.noCert
    }
    print("  ✓ CERT RETURNED")
    print("  cert (base64, first 80 chars): \(cert.prefix(80))...")
    print("  cert length: \(cert.count) chars")
    if let hostSigners = rc7?.hostSigners {
        for hs in hostSigners {
            print("  host_signer: \(hs.domainName) (\(hs.checkingKeys.count) key(s))")
        }
    }
    print("")
    print("=== SPIKE PASSED ===")
    print("Part A (software signer):  \(args.signerKind == .software ? "PASSED" : "skipped")")
    print("Part B (SEP signer):       \(args.signerKind == .sep && !args.biometry ? "PASSED" : "skipped")")
    print("Part C (SEP + biometry):   \(args.signerKind == .sep && args.biometry ? "PASSED" : "skipped")")
    print("Wire format accepted by Teleport. Cert TTL: \(args.ttl)s")
}

main()
