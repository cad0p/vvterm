// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  Fixture generator — produces byte-exact reference outputs from Teleport's
//  lib/auth/touchid/api.go (pinned v18.9.1). Run with `./regenerate.sh`.
//
//  The Swift tests in Tests/SEPWebAuthnTests/FixtureTests.swift byte-compare
//  their output against these fixtures to catch transcription errors in the
//  CBOR / attestation / clientDataJSON building.
//
//  The fixtures use FIXED inputs (challenge, origin, rpID, credential ID,
//  public key) so the output is deterministic. The signature is produced by
//  a fixed P-256 private key (not the SEP — pure software, for portability),
//  so even the signature is reproducible.

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"

	"github.com/fxamacker/cbor/v2"
)

// Test vector — MUST match FixtureTests.swift exactly.
const (
	origin       = "https://goteleport.com"
	rpID         = "goteleport.com"
	credentialID = "11111111-2222-3333-4444-555555555555"
)

var challenge = []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fixture generation failed:", err)
		os.Exit(1)
	}
}

func run() error {
	outDir := filepath.Join("fixtures", "expected")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}

	// Generate a FIXED P-256 keypair for deterministic signatures.
	// In production we'd use the SEP, but for fixtures we need reproducibility.
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate key: %w", err)
	}

	// Serialize public key in ANSI X9.63 form (0x04 || X || Y).
	pubKeyRaw := elliptic.Marshal(elliptic.P256(), privKey.X, privKey.Y)
	if len(pubKeyRaw) != 65 || pubKeyRaw[0] != 0x04 {
		return fmt.Errorf("unexpected pub key shape: %d bytes, first 0x%02x", len(pubKeyRaw), pubKeyRaw[0])
	}
	if err := writeBinary(outDir, "pub_key_raw.bin", pubKeyRaw); err != nil {
		return err
	}
	fmt.Printf("wrote pub_key_raw.bin (%d bytes)\n", len(pubKeyRaw))

	// Parse via ecdsaPublicKeyFromRaw (inlined copy of Teleport's
	// lib/darwin.ECDSAPublicKeyFromRaw) to confirm our pubKeyRaw is well-formed.
	if _, err := ecdsaPublicKeyFromRaw(pubKeyRaw); err != nil {
		return fmt.Errorf("ecdsaPublicKeyFromRaw: %w", err)
	}

	// Build the COSE EC2 public key CBOR, mirroring api.go:284-307.
	x := make([]byte, 32)
	y := make([]byte, 32)
	privKey.X.FillBytes(x)
	privKey.Y.FillBytes(y)

	type webauthncoseEC2 struct {
		// Match the webauthncose.EC2PublicKeyData type (keyasint tags).
		// We inline it here to avoid importing the vendored webauthncose
		// package (which has build constraints on some platforms).
		Kty int64  `cbor:"1,keyasint"`
		Alg int64  `cbor:"3,keyasint"`
		Crv int64  `cbor:"-1,keyasint"`
		X   []byte `cbor:"-2,keyasint"`
		Y   []byte `cbor:"-3,keyasint"`
	}
	// Note: the cbor struct tags above must match webauthncose.EC2PublicKeyData
	// EXACTLY (keyasint + omitempty for -1/-2/-3). The omitempty on the
	// negative keys matters: if the value is nil, the key is omitted. Since
	// we always set non-nil values, omitempty doesn't affect output.
	ec2 := webauthncoseEC2{
		Kty: 2,   // EllipticKey
		Alg: -7,  // AlgES256
		Crv: 1,   // P-256
		X:   x,
		Y:   y,
	}
	pubKeyCBOR, err := cbor.Marshal(ec2)
	if err != nil {
		return fmt.Errorf("cbor marshal ec2: %w", err)
	}
	if err := writeBinary(outDir, "cose_pubkey.cbor", pubKeyCBOR); err != nil {
		return err
	}
	fmt.Printf("wrote cose_pubkey.cbor (%d bytes)\n", len(pubKeyCBOR))

	// Build collectedClientData + authenticatorData for CREATE ceremony.
	// Mirrors api.go:387-451 (makeAttestationData).
	//
	// Go's encoding/json emits struct fields in declaration order, so the
	// JSON keys appear as type, challenge, origin — matching api.go's
	// collectedClientData struct (api.go:379-385). Using a struct (not a
	// map) is load-bearing: Go map iteration order is randomized.
	type collectedClientData struct {
		Type      string `json:"type"`
		Challenge string `json:"challenge"`
		Origin    string `json:"origin"`
	}
	ccdStruct := collectedClientData{
		Type:      "webauthn.create",
		Challenge: base64.RawURLEncoding.EncodeToString(challenge),
		Origin:    origin,
	}
	ccdJSON, err := json.Marshal(ccdStruct)
	if err != nil {
		return err
	}
	if err := writeBinary(outDir, "client_data_create.json", ccdJSON); err != nil {
		return err
	}
	fmt.Printf("wrote client_data_create.json (%d bytes): %s\n", len(ccdJSON), ccdJSON)

	ccdStructGet := collectedClientData{
		Type:      "webauthn.get",
		Challenge: base64.RawURLEncoding.EncodeToString(challenge),
		Origin:    origin,
	}
	ccdJSONGet, err := json.Marshal(ccdStructGet)
	if err != nil {
		return err
	}
	if err := writeBinary(outDir, "client_data_get.json", ccdJSONGet); err != nil {
		return err
	}
	fmt.Printf("wrote client_data_get.json (%d bytes): %s\n", len(ccdJSONGet), ccdJSONGet)

	// authenticatorData for CREATE.
	rpIDHash := sha256.Sum256([]byte(rpID))
	ccdHash := sha256.Sum256(ccdJSON)
	flags := byte(0x01 | 0x04 | 0x40) // UP | UV | AT
	authData := make([]byte, 0, 37+16+2+len(credentialID)+len(pubKeyCBOR))
	authData = append(authData, rpIDHash[:]...)          // 32
	authData = append(authData, flags)                   // 1
	authData = append(authData, 0, 0, 0, 0)               // signCount (4, BE, 0)
	authData = append(authData, make([]byte, 16)...)     // aaguid (16 zero bytes)
	credIDLen := uint16(len(credentialID))
	authData = append(authData, byte(credIDLen>>8), byte(credIDLen&0xff))
	authData = append(authData, []byte(credentialID)...)
	authData = append(authData, pubKeyCBOR...)
	if err := writeBinary(outDir, "auth_data_create.bin", authData); err != nil {
		return err
	}
	fmt.Printf("wrote auth_data_create.bin (%d bytes)\n", len(authData))

	// authenticatorData for GET (no attested credential data).
	flagsGet := byte(0x01 | 0x04) // UP | UV
	authDataGet := make([]byte, 0, 37)
	authDataGet = append(authDataGet, rpIDHash[:]...)
	authDataGet = append(authDataGet, flagsGet)
	authDataGet = append(authDataGet, 0, 0, 0, 0)
	if err := writeBinary(outDir, "auth_data_get.bin", authDataGet); err != nil {
		return err
	}
	fmt.Printf("wrote auth_data_get.bin (%d bytes)\n", len(authDataGet))

	// Compute the digest that gets signed. Mirrors api.go:445:
	//   digest = sha256(authData || sha256(ccdJSON))
	// api.go then passes `digest` to native.Authenticate, which calls
	// SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256, digest, ...).
	// The SEP's X962SHA256 algorithm hashes the input AGAIN internally, so
	// the actual signed bytes are sha256(digest) = sha256(sha256(authData || sha256(ccdJSON))).
	//
	// The Swift port reproduces this exactly — see SecureEnclaveSigner.sign
	// for the double-hash note. The fixture generator must sign the same
	// sha256(digest) bytes to produce a comparable signature.
	dataToSign := append(authData, ccdHash[:]...)
	digest := sha256.Sum256(dataToSign)

	// Sign sha256(digest) — the double-hashed form — with the fixed
	// private key, to produce a deterministic signature matching what the
	// SEP / SoftwareSigner would produce.
	doubleHash := sha256.Sum256(digest[:])
	sigDER, err := ecdsa.SignASN1(rand.Reader, privKey, doubleHash[:])
	if err != nil {
		return fmt.Errorf("ecdsa sign: %w", err)
	}
	if err := writeBinary(outDir, "signature_create.der", sigDER); err != nil {
		return err
	}
	fmt.Printf("wrote signature_create.der (%d bytes)\n", len(sigDER))

	// Build the attestation object as a CLEAN W3C-compliant map (not the
	// protocol.AttestationObject struct, which would include a noisy
	// zero-value "AuthData" field — see Attestation.swift's comment).
	//
	// Using a map[string]interface{} with default cbor.Marshal produces
	// SortNone (insertion-order) output. To get canonical (length-first
	// then bytewise) ordering, use CTAP2EncOptions — matching what a
	// spec-compliant WebAuthn client produces and what the server's
	// CTAP2 decoder expects.
	//
	// Canonical key order for {"fmt","attStmt","authData"}:
	//   "attStmt"  (7 bytes)  → encodes to 0x67 61 74 74 53 74 6d 74 (8 bytes)
	//   "authData" (8 bytes)  → encodes to 0x68 61 75 74 68 44 61 74 61 (9 bytes)
	//   "fmt"      (3 bytes)  → encodes to 0x63 66 6d 74 (4 bytes)
	// Length-first sort: 3, 7, 8 → "fmt", "attStmt", "authData"
	ctap2Mode, _ := cbor.CTAP2EncOptions().EncMode()
	attObj, err := ctap2Mode.Marshal(map[string]interface{}{
		"fmt":      "packed",
		"attStmt":  map[string]interface{}{"alg": int64(-7), "sig": sigDER},
		"authData": authData,
	})
	if err != nil {
		return fmt.Errorf("cbor marshal attObj: %w", err)
	}
	if err := writeBinary(outDir, "attestation_object_create.cbor", attObj); err != nil {
		return err
	}
	fmt.Printf("wrote attestation_object_create.cbor (%d bytes)\n", len(attObj))

	// Print the first 32 bytes of the attObj so the Swift test can sanity-check
	// the head (should start with 0xa3 — map(3) — because we emit exactly 3 keys).
	fmt.Printf("attObj head: %s\n", hex.EncodeToString(attObj[:min(32, len(attObj))]))

	// Print the public key + private key hex so the Swift side could (if
	// it wanted) reproduce the exact signature. We don't use this in the
	// Swift tests (we verify the signature against the pub key instead),
	// but it's useful for debugging.
	fmt.Println()
	fmt.Println("=== fixture inputs ===")
	fmt.Printf("origin:        %s\n", origin)
	fmt.Printf("rpID:          %s\n", rpID)
	fmt.Printf("credentialID:  %s\n", credentialID)
	fmt.Printf("challenge:     %x\n", challenge)
	fmt.Printf("pubKeyRaw:     %s\n", hex.EncodeToString(pubKeyRaw))
	fmt.Printf("privKey D:     %x\n", privKey.D.Bytes())
	fmt.Println()
	fmt.Println("=== files written to fixtures/expected/ ===")
	fmt.Println("  pub_key_raw.bin             (65 bytes, 0x04 || X || Y)")
	fmt.Println("  cose_pubkey.cbor            (CBOR COSE EC2 key)")
	fmt.Println("  client_data_create.json     (webauthn.create)")
	fmt.Println("  client_data_get.json        (webauthn.get)")
	fmt.Println("  auth_data_create.bin        (with attested credential data)")
	fmt.Println("  auth_data_get.bin           (assertion, no attested data)")
	fmt.Println("  signature_create.der        (deterministic ECDSA DER sig)")
	fmt.Println("  attestation_object_create.cbor (full attObj, matches api.go:297)")

	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func writeBinary(dir, name string, data []byte) error {
	path := filepath.Join(dir, name)
	return os.WriteFile(path, data, 0o644)
}

// ecdsaPublicKeyFromRaw is an inlined copy of Teleport's
// lib/darwin.ECDSAPublicKeyFromRaw (teleport v18.9.1, AGPL-3.0). It parses the
// ANSI X9.63 representation (0x04 || X || Y) produced by
// SecKeyCopyExternalRepresentation. Inlined here to avoid pulling the entire
// teleport module into the fixture generator's dep graph.
func ecdsaPublicKeyFromRaw(pubKeyRaw []byte) (*ecdsa.PublicKey, error) {
	switch l := len(pubKeyRaw); {
	case l < 3:
		return nil, fmt.Errorf("public key representation too small (%v bytes)", l)
	case l%2 != 1:
		return nil, fmt.Errorf("public key representation has unexpected length (%v bytes)", l)
	case pubKeyRaw[0] != 0x04:
		return nil, fmt.Errorf("public key representation starts with unexpected byte (%#x vs 0x4)", pubKeyRaw[0])
	}
	pubKeyRaw = pubKeyRaw[1:] // skip 0x4
	l := len(pubKeyRaw) / 2
	x := pubKeyRaw[:l]
	y := pubKeyRaw[l:]
	return &ecdsa.PublicKey{
		Curve: elliptic.P256(),
		X:     (&big.Int{}).SetBytes(x),
		Y:     (&big.Int{}).SetBytes(y),
	}, nil
}
