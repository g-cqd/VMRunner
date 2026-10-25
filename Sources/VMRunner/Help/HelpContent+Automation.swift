extension HelpCatalog {
    /// The control service for scripts and AI agents, and the switches that open it.
    static let automation: [HelpTopic: HelpEntry] = [
        .agentAccess: HelpEntry(
            area: .security,
            title: "Agent access",
            summary: "Lets scripts and AI agents with a control token see this machine and start or stop it. Off by default.",
            paragraphs: [
                "VMRunner can be driven by scripts and AI agents through its control service, a private local socket on your Mac "
                    + "that stays off until you turn it on in Settings. Each machine decides for itself: an agent sees and acts on "
                    + "a machine only while its **Allow agent access** switch is on.",
                "With it on, an agent that holds a control token can list the machine, read its state, and start or stop it, as "
                    + "far as its token allows. It cannot see the screen, type into the guest or run commands in it.",
                "The Isolated and Hardened profiles turn it off. While it is on, \"What this machine can reach\" says so.",
            ],
            advanced: [
                "An agent's start never asks you anything: if the machine uses folders or disks you have not approved in VMRunner, "
                    + "the start is refused. Start the machine once from the app to approve them."
            ],
            related: [.exposureSummary, .securityProfiles, .serialConsole]
        ),
        .controlService: HelpEntry(
            area: .app,
            title: "Control service for scripts and agents",
            summary: "A private local socket through which scripts and AI agents with a token control machines. Off by default.",
            paragraphs: [
                "The control service lets a script or an AI agent on this Mac list your machines, read their state, and start and "
                    + "stop them. It is off until you turn on **Let scripts and AI agents control machines** in Settings.",
                "Three things must all be true before anything happens: the service is on, the client presents a control token "
                    + "that has the capability it needs (list, read state, start, stop), and the machine's own **Allow agent "
                    + "access** switch is on.",
                "Only your user account can open the socket, and nothing listens on the network. Every request refused for "
                    + "its token, its capability or a machine's access is logged, without the token.",
                "Your organisation can keep it off with the managed setting `AllowControlService`.",
            ],
            advanced: [
                "The socket is `Control/control.sock` in VMRunner's data folder (`~/Library/Application Support/VMRunner`), mode "
                    + "0600 in a folder only you can enter. The protocol is JSON-RPC 2.0, one request per line: `machines.list`, "
                    + "`machines.state`, `machines.start` and `machines.stop`, each with `token` in its `params`, and `machine` "
                    + "(the machine's id) for the last three. `machines.stop` asks the guest to shut down; with `force` set to "
                    + "true it cuts the power. A container machine is listed with `workload` set to `container` (a virtual machine "
                    + "has `vm`) and its `guest` is `linux`; `machines.stop` asks the container to stop, and with `force` kills it. "
                    + "Batches are refused.",
                "Limits: a request is at most 64 KiB; 4 clients at a time; a client is disconnected after 10 seconds without a "
                    + "request; an answer that would take over 2 minutes says it timed out, and what it started goes on.",
                #"From a terminal: `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"machines.list","params":{"token":"…"}}' "#
                    + "| nc -U <socket>`.",
            ],
            related: [.agentAccess, .controlTokens, .settings, .managedSettings]
        ),
        .controlTokens: HelpEntry(
            area: .app,
            title: "Control tokens",
            summary: "Keys that each let one script or agent use the control service, limited to what you tick.",
            paragraphs: [
                "Give each script or agent its own token, so you can see what each may do and revoke one without touching "
                    + "the others.",
                "To make one, type a name, tick what it may do (list machines, read their state, start, stop), and choose "
                    + "**Create Token**. The token is shown once: copy it then. VMRunner keeps only a fingerprint of it and "
                    + "cannot show it again; if it is lost, revoke it and make a new one.",
                "**Revoke** removes a token: its next request is refused, even on a connection that is already open.",
                "A token works only while the control service is on, and only on machines whose **Allow agent access** switch "
                    + "is on.",
            ],
            advanced: [
                "A token is 256 random bits, written `vmrc_` and 64 hexadecimal digits. VMRunner stores its SHA-256 digest, "
                    + "never the token, in `Control/tokens.json` (mode 0600) in its data folder, and compares digests in "
                    + "constant time. At most 32 tokens. A token can also be limited to some machines; Settings does not offer "
                    + "that yet."
            ],
            related: [.controlService, .agentAccess]
        ),
    ]
}
