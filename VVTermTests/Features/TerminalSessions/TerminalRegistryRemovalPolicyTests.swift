import Foundation
import Testing
@testable import VVTerm

struct TerminalRegistryRemovalPolicyTests {
    private final class TerminalIdentity {}

    @Test
    func staleDismantleCannotRemoveReplacementTerminal() {
        let dismantledTerminal = TerminalIdentity()
        let replacementTerminal = TerminalIdentity()

        #expect(!TerminalRegistryRemovalPolicy.shouldRemove(
            registered: ObjectIdentifier(replacementTerminal),
            dismantled: ObjectIdentifier(dismantledTerminal)
        ))
    }

    @Test
    func dismantleCanRemoveItsMatchingTerminal() {
        let terminal = TerminalIdentity()

        #expect(TerminalRegistryRemovalPolicy.shouldRemove(
            registered: ObjectIdentifier(terminal),
            dismantled: ObjectIdentifier(terminal)
        ))
    }
}
