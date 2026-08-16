import SwiftUI

/// The assistant affordance: one small icon in the analysis toolbar, next to the
/// reconciliation "?" and the theme toggle — SPEC-14 phase 4.
///
/// Deliberately *not* a modal. Handing a scan to an assistant is an option, not
/// a step in using the app, so it lives where the other optional explanations
/// live and stays out of the way until asked for.
///
/// `sparkles` rather than Claude's own mark: naming the tool is fine, shipping
/// someone else's logo in a third-party app is not.
struct AssistantButton: View {
    let app: AppModel
    @Environment(\.theme) private var theme
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "sparkles")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary)
        .help("Ask an assistant about this scan")
        .accessibilityLabel("Assistant")
        .accessibilityHint("Copy a briefing, or connect Claude Code to this scan")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AssistantPanel(app: app)
                .environment(\.theme, theme)
        }
    }
}

private struct AssistantPanel: View {
    let app: AppModel
    @Environment(\.theme) private var theme

    @State private var status: Status = .checking
    @State private var plan: ClaudeIntegration.Plan?
    @State private var busy = false
    @State private var message: String?
    @State private var copied = false

    /// Names the server so the session reaches for it instead of shelling out to
    /// `du`, and asks for the map marks so the conclusions land somewhere the
    /// user can see. Phrased to match the shipped skill's own trigger wording.
    private static let starterPrompt =
        "What's taking up space on my disk? Use the spacematters MCP server, "
        + "and mark what you find on the map as you go."

    private enum Status {
        case checking
        /// Skill installed and the server registered — nothing left to do.
        case ready
        case notSetUp(skillInstalled: Bool, cliFound: Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about this scan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            briefingRow
            Divider().overlay(theme.separator)
            integrationRow

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 380)
        // The toolbar wraps its whole row in `.lineLimit(1)` to stay one line
        // high (#12); a popover is a child of that view, so it inherits the
        // clamp and every explanation here truncates to "…". Undo it locally.
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .background(theme.panelBackground)
        .task { await refresh() }
    }

    // MARK: Clipboard — works with any assistant, needs no setup at all

    private var briefingRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                app.copyBriefing()
                copied = true
            } label: {
                Label(copied ? "Briefing copied" : "Copy briefing", systemImage: "doc.on.clipboard")
            }
            .disabled(!app.canCopyBriefing)
            Text("A few thousand tokens describing what you're looking at. Paste it into any assistant. (⌘⇧C)")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Claude Code

    @ViewBuilder
    private var integrationRow: some View {
        switch status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking Claude Code…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude Code is connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)

                // "It's connected" is a status, not an action. The three steps
                // and a ready-made prompt are what actually gets someone from
                // here to an answer.
                // Without `fixedSize` the stack compresses this multi-line Text
                // to one line and ellipsises the other two steps away.
                // A session builds its tool list at startup, so one that was
                // already open when the server was registered will not see it
                // and will say so in confusing ways ("no spacematters tools").
                // Saying this here is the difference between the feature working
                // and the feature looking broken.
                // One literal, not a `+` concatenation: SwiftUI only parses
                // markdown out of a string *literal*, so a built-up String would
                // render the asterisks and backticks verbatim.
                Text("1. Open a **new** terminal session — run `claude`\n2. Paste the prompt below\n\nAlready in a session? It won't see the server yet: run `/mcp` there and reconnect **spacematters**.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.starterPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.separator.opacity(0.35)))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.starterPrompt, forType: .string)
                    message = "Prompt copied. Keep this window open — the session will read "
                        + "this scan and can mark folders on the map."
                } label: {
                    Label("Copy prompt", systemImage: "text.badge.checkmark")
                }
            }

        case .notSetUp(let skillInstalled, let cliFound):
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Claude Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text("Lets a session query this scan through a read-only server that has no way "
                     + "to delete anything, and installs a skill teaching it how to read one.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let plan {
                    // Exactly what the button writes, before it writes it.
                    VStack(alignment: .leading, spacing: 2) {
                        if !skillInstalled { Text("writes  \(plan.skillDestination.path)") }
                        Text("runs  \(plan.registerCommand)")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button(cliFound ? "Set up" : "Install skill") {
                        Task { await install() }
                    }
                    .disabled(busy || plan == nil)
                    Button("Copy command") {
                        guard let plan else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.registerCommand, forType: .string)
                        message = "Command copied — run it in a terminal, then start a new session."
                    }
                    .disabled(plan == nil)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    // MARK: Status

    private func refresh() async {
        let plan = ClaudeIntegration.plan()
        self.plan = plan
        // Off the main actor: ~/.claude.json carries session history and can run
        // to megabytes, and this happens every time the popover opens.
        let registered = await Task.detached(priority: .userInitiated) {
            ClaudeIntegration.isRegistered()
        }.value
        status = (registered && plan.skillAlreadyInstalled)
            ? .ready
            : .notSetUp(skillInstalled: plan.skillAlreadyInstalled, cliFound: plan.cliPath != nil)
    }

    private func install() async {
        guard let plan else { return }
        busy = true
        defer { busy = false }
        switch ClaudeIntegration.apply(plan) {
        case .done(let registered):
            message = registered
                ? "Registered. A session that is already open won't see it — start a new one, "
                  + "or run /mcp there and reconnect."
                : "Skill installed. Copy the command above and run it to register the server."
        case .failed(let text):
            message = text
        }
        await refresh()
    }
}
