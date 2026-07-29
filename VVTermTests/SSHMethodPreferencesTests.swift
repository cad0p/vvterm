import Testing
@testable import VVTerm

/// Regression coverage for the libssh2 KEX + hostkey method preferences used
/// by `SSHClient.connect`. Teleport's TLS-routing proxy (like OpenSSH 8.8+)
/// disables `ssh-rsa` (SHA-1) hostkey signatures by default, so libssh2 must
/// offer modern algorithms first or KEX fails with
/// `LIBSSH2_ERROR_KEX_FAILURE` (-5). These tests pin the ordering without
/// requiring a live libssh2 session.
struct SSHMethodPreferencesTests {
    @Test
    func kexPrefersCurve25519First() {
        let algorithms = SSHMethodPreferences.kex.split(separator: ",")
        #expect(algorithms.first == "curve25519-sha256")
        #expect(algorithms.contains("curve25519-sha256@libssh.org"))
    }

    @Test
    func kexIncludesModernECDHAndDH() {
        let kex = SSHMethodPreferences.kex
        #expect(kex.contains("ecdh-sha2-nistp256"))
        #expect(kex.contains("ecdh-sha2-nistp384"))
        #expect(kex.contains("ecdh-sha2-nistp521"))
        #expect(kex.contains("diffie-hellman-group-exchange-sha256"))
    }

    @Test
    func hostkeyPrefersEd25519AndRsaSha2BeforeLegacySshRsa() {
        let algorithms = SSHMethodPreferences.hostkey.split(separator: ",")
        #expect(algorithms.first == "ssh-ed25519")

        let ed25519Index = algorithms.firstIndex(of: "ssh-ed25519")
        let rsa256Index = algorithms.firstIndex(of: "rsa-sha2-256")
        let rsa512Index = algorithms.firstIndex(of: "rsa-sha2-512")
        let sshRsaIndex = algorithms.firstIndex(of: "ssh-rsa")

        #expect(ed25519Index != nil)
        #expect(rsa256Index != nil)
        #expect(rsa512Index != nil)
        // `ssh-rsa` (SHA-1) must remain available as a fallback but must NOT
        // be offered before the SHA-2 / Ed25519 algorithms — Teleport's proxy
        // rejects it.
        #expect(sshRsaIndex != nil)
        #expect(sshRsaIndex! > ed25519Index!)
        #expect(sshRsaIndex! > rsa256Index!)
        #expect(sshRsaIndex! > rsa512Index!)
    }

    @Test
    func hostkeyIncludesEcdsaVariants() {
        let hostkey = SSHMethodPreferences.hostkey
        #expect(hostkey.contains("ecdsa-sha2-nistp256"))
        #expect(hostkey.contains("ecdsa-sha2-nistp384"))
        #expect(hostkey.contains("ecdsa-sha2-nistp521"))
    }

    @Test
    func hostkeyIncludesCertificateVariants() {
        // Teleport's proxy structurally refuses plain hostkeys (see
        // lib/sshutils/server.go validateHostSigner) and advertises ONLY a
        // certificate hostkey algorithm. If we don't offer at least one
        // `-cert-v01@openssh.com` variant, KEX fails with -5. libssh2 1.11.1
        // supports all of these with the OpenSSL backend.
        let hostkey = SSHMethodPreferences.hostkey
        #expect(hostkey.contains("ssh-ed25519-cert-v01@openssh.com"))
        #expect(hostkey.contains("ecdsa-sha2-nistp256-cert-v01@openssh.com"))
        #expect(hostkey.contains("ecdsa-sha2-nistp384-cert-v01@openssh.com"))
        #expect(hostkey.contains("ecdsa-sha2-nistp521-cert-v01@openssh.com"))
        #expect(hostkey.contains("rsa-sha2-256-cert-v01@openssh.com"))
        #expect(hostkey.contains("rsa-sha2-512-cert-v01@openssh.com"))
        #expect(hostkey.contains("ssh-rsa-cert-v01@openssh.com"))
    }

    @Test
    func preferencesAreNonEmptyAndCommaDelimited() {
        #expect(!SSHMethodPreferences.kex.isEmpty)
        #expect(!SSHMethodPreferences.hostkey.isEmpty)
        #expect(!SSHMethodPreferences.kex.contains(",,"))
        #expect(!SSHMethodPreferences.hostkey.contains(",,"))
        #expect(!SSHMethodPreferences.kex.hasPrefix(","))
        #expect(!SSHMethodPreferences.hostkey.hasSuffix(","))
    }
}
