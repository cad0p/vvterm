struct TerminalContextMenuActions {
    let focus: () -> Void
    let splitRight: () -> Void
    let splitLeft: () -> Void
    let splitDown: () -> Void
    let splitUp: () -> Void
    let currentTitle: () -> String
    let setTitle: (String?) -> Void
}
