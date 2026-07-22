// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  Headless ID fixture generator — produces the expected
//  headlessAuthenticationID for a fixed SSH public key, using Teleport's
//  exact derivation (lib/services/headlessauthn.go:57 +
//  google/uuid v1.6.0 NewHash).
//
//  The Swift test in the iotest app compares its HeadlessID.compute()
//  output against this fixture to catch transcription errors in the
//  SHA256-UUID-v5 port.
//
//  This generator is self-contained: it inlines the one Teleport function
//  it needs (NewHeadlessAuthenticationID, a 3-line wrapper around
//  uuid.NewHash) to avoid pulling the entire teleport module. It depends
//  only on google/uuid + the Go stdlib.
//
//  Run with: go run ./gen/headless_id.go
//  (invoked by spikes/sep-webauthn/fixtures/regenerate.sh)

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/google/uuid"
)

// Test vector — MUST match the Swift HeadlessIDTests fixture exactly.
// This is a fixed ed25519 SSH public key (authorized_keys format, with
// the trailing newline that ssh.MarshalAuthorizedKey appends).
const (
	// A fixed ed25519 SSH public key for deterministic fixtures. The
	// 32-byte raw pubkey is all 0xff bytes (so the base64 is predictable).
	//
	// ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP////////////////////////////////////8 test
	//
	// We construct it programmatically below to avoid transcription errors.
	fixedSSHPubKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP////////////////////////////////////8 test"
)

// NewHeadlessAuthenticationID is an inlined copy of Teleport's
// lib/services/headlessauthn.go:57 (teleport v18.9.1, AGPL-3.0).
// It returns a SHA256-based UUID v5 with uuid.Nil as the namespace
// and the SSH public key bytes as the name.
func NewHeadlessAuthenticationID(pubKey []byte) string {
	return uuid.NewHash(sha256.New(), uuid.Nil, pubKey, 5).String()
}

func main() {
	// The SSH public key bytes — exactly what ssh.MarshalAuthorizedKey
	// produces (with the trailing newline).
	pubKeyBytes := []byte(fixedSSHPubKeyLine + "\n")

	// Compute the headless authentication ID.
	id := NewHeadlessAuthenticationID(pubKeyBytes)

	// Write the fixture.
	outDir := filepath.Join("fixtures", "expected")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "mkdir failed:", err)
		os.Exit(1)
	}

	// Write the SSH pub key (the input).
	if err := os.WriteFile(filepath.Join(outDir, "headless_ssh_pubkey.txt"), pubKeyBytes, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write pubkey failed:", err)
		os.Exit(1)
	}
	fmt.Printf("wrote headless_ssh_pubkey.txt (%d bytes): %s\n", len(pubKeyBytes), fixedSSHPubKeyLine)

	// Write the expected headless ID (the output).
	if err := os.WriteFile(filepath.Join(outDir, "headless_id.txt"), []byte(id), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write id failed:", err)
		os.Exit(1)
	}
	fmt.Printf("wrote headless_id.txt: %s\n", id)

	// Also write the raw SHA256 digest (first 16 bytes, before version/variant
	// bits are set) for debugging.
	h := sha256.New()
	h.Write(make([]byte, 16)) // uuid.Nil = 16 zero bytes
	h.Write(pubKeyBytes)
	digest := h.Sum(nil)
	if err := os.WriteFile(filepath.Join(outDir, "headless_digest.bin"), digest[:16], 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write digest failed:", err)
		os.Exit(1)
	}
	fmt.Printf("wrote headless_digest.bin (16 bytes): %s\n", hex.EncodeToString(digest[:16]))
	fmt.Printf("  (version byte[6] = 0x%02x → 0x%02x, variant byte[8] = 0x%02x → 0x%02x)\n",
		digest[6], (digest[6]&0x0f)|0x50,
		digest[8], (digest[8]&0x3f)|0x80)
}
