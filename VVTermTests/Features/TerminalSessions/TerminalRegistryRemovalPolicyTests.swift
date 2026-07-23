import Foundation
import Testing
@testable import VVTerm

struct TerminalRegistryPolicyTests {
    private final class TerminalIdentity {}

    @Test
    func staleDismantleCannotRemoveReplacementTerminal() {
        let dismantledTerminal = TerminalIdentity()
        let replacementTerminal = TerminalIdentity()

        #expect(!TerminalRegistryPolicy.shouldRemove(
            registered: ObjectIdentifier(replacementTerminal),
            dismantled: ObjectIdentifier(dismantledTerminal)
        ))
    }

    @Test
    func dismantleCanRemoveItsMatchingTerminal() {
        let terminal = TerminalIdentity()

        #expect(TerminalRegistryPolicy.shouldRemove(
            registered: ObjectIdentifier(terminal),
            dismantled: ObjectIdentifier(terminal)
        ))
    }

    @Test
    func staleDetachPublishesCurrentReattachedState() {
        let terminal = TerminalIdentity()

        #expect(TerminalRegistryPolicy.attachmentToPublish(
            registered: ObjectIdentifier(terminal),
            reporting: ObjectIdentifier(terminal),
            currentAttachment: true
        ) == true)
    }

    @Test
    func currentDetachPublishesDetachedState() {
        let terminal = TerminalIdentity()

        #expect(TerminalRegistryPolicy.attachmentToPublish(
            registered: ObjectIdentifier(terminal),
            reporting: ObjectIdentifier(terminal),
            currentAttachment: false
        ) == false)
    }

    @Test
    func staleAttachmentFromReplacedTerminalIsIgnored() {
        let registered = TerminalIdentity()
        let staleReporter = TerminalIdentity()

        #expect(TerminalRegistryPolicy.attachmentToPublish(
            registered: ObjectIdentifier(registered),
            reporting: ObjectIdentifier(staleReporter),
            currentAttachment: false
        ) == nil)
    }
}
