import Foundation
import Testing
@testable import VVTerm

struct RemoteFilePermissionTests {
    @Test
    func draftUpdatesBitsAndSummaries() {
        var draft = RemoteFilePermissionDraft(accessBits: 0o640)
        draft.set(true, capability: .execute, for: .owner)
        draft.set(false, capability: .read, for: .group)

        // 0o640 (rw-r-----) → set owner-x → 0o740 (rwxr-----) → clear group-r → 0o700 (rwx------).
        // The earlier expected value (0o740 / "rwxr-----") contradicted the
        // `set(false, .read, .group)` operation: it left group-read set, which
        // is exactly what clearing group-read must not do.
        #expect(draft.accessBits == 0o700)
        #expect(draft.octalSummary == "700")
        #expect(draft.symbolicSummary == "rwx------")
    }

    @Test
    func capabilityBitMappingMatchesExpectedAudienceMasks() {
        #expect(RemoteFilePermissionCapability.read.bit(for: .owner) == UInt32(LIBSSH2_SFTP_S_IRUSR))
        #expect(RemoteFilePermissionCapability.write.bit(for: .group) == UInt32(LIBSSH2_SFTP_S_IWGRP))
        #expect(RemoteFilePermissionCapability.execute.bit(for: .everyone) == UInt32(LIBSSH2_SFTP_S_IXOTH))
    }
}
