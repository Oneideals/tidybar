import AppKit

public final class TidyBarAboutWindowController: NSWindowController {
    public static let shared = TidyBarAboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.aboutTitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let window = self.window, let root = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])

        // 1. App Icon
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let appIcon = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage {
            iconView.image = appIcon
        } else {
            iconView.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "TidyBar")
        }
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96)
        ])
        stack.addArrangedSubview(iconView)

        // 2. Title & Version
        let titleLabel = NSTextField(labelWithString: "TidyBar")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(titleLabel)

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        // 3. Tagline
        let taglineLabel = NSTextField(wrappingLabelWithString: L10n.appTagline)
        taglineLabel.font = NSFont.systemFont(ofSize: 12)
        taglineLabel.alignment = .center
        taglineLabel.textColor = .labelColor
        stack.addArrangedSubview(taglineLabel)

        stack.setCustomSpacing(16, after: taglineLabel)

        // 4. Action Buttons (GitHub / Issues / Privacy)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let repoBtn = NSButton(title: L10n.gitHubRepoButton, target: self, action: #selector(openRepo))
        repoBtn.bezelStyle = .rounded
        repoBtn.font = NSFont.systemFont(ofSize: 11)
        buttonRow.addArrangedSubview(repoBtn)

        let feedbackBtn = NSButton(title: L10n.feedbackButton, target: self, action: #selector(openFeedback))
        feedbackBtn.bezelStyle = .rounded
        feedbackBtn.font = NSFont.systemFont(ofSize: 11)
        buttonRow.addArrangedSubview(feedbackBtn)

        let privacyBtn = NSButton(title: L10n.viewPrivacyPolicyButton, target: self, action: #selector(openPrivacy))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 11)
        buttonRow.addArrangedSubview(privacyBtn)

        stack.addArrangedSubview(buttonRow)

        stack.setCustomSpacing(18, after: buttonRow)

        // 5. Copyright
        let copyrightLabel = NSTextField(labelWithString: L10n.copyrightNotice)
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(copyrightLabel)
    }

    public func show() {
        window?.title = L10n.aboutTitle
        showWindow(nil)
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openRepo() {
        if let url = URL(string: "https://github.com/Oneideals/tidybar") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFeedback() {
        DiagnosticExporter.openGitHubIssue()
    }

    @objc private func openPrivacy() {
        DiagnosticExporter.openPrivacyPolicy()
    }
}
