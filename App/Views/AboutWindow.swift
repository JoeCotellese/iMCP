// ABOUTME: The About window: app name, version, copyright, contact and source links.
// ABOUTME: Credits upstream iMCP and carries Apple's trademark acknowledgment for "Mac".

import AppKit
import SwiftUI

class AboutWindowController: NSWindowController {
    convenience init() {
        let hostingView = NSHostingView(rootView: AboutView(content: .main))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Pontemac"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

struct AboutContent {
    var appName: String
    var version: String?
    var copyright: String?

    static let contactEmail = "pontemac@cotellese.me"
    static let contactURL = URL(string: "mailto:pontemac@cotellese.me")!
    static let repositoryURL = URL(string: "https://github.com/JoeCotellese/pontemac-mcp")!
    static let reportIssueURL = URL(string: "https://github.com/JoeCotellese/pontemac-mcp/issues/new")!
    static let upstreamURL = URL(string: "https://github.com/mattt/iMCP")!
    static let trademark =
        "Mac is a trademark of Apple Inc., registered in the U.S. and other countries."

    static var main: AboutContent {
        AboutContent(
            appName: Bundle.main.name ?? "Pontemac",
            version: Bundle.main.shortVersionString,
            copyright: Bundle.main.copyright
        )
    }
}

struct AboutView: View {
    let content: AboutContent

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                // Left column - Icon
                Image(.menuIconOn)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)

                // Right column - App info and links
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.appName)
                            .font(.system(size: 24, weight: .medium))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("aboutAppNameText")

                        if let version = content.version {
                            Text("Version \(version)")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Link(AboutContent.contactEmail, destination: AboutContent.contactURL)
                            .accessibilityLabel("Email \(AboutContent.contactEmail)")
                            .accessibilityIdentifier("aboutContactLink")

                        Link("Source on GitHub", destination: AboutContent.repositoryURL)
                            .accessibilityLabel("Source code on GitHub")
                            .accessibilityIdentifier("aboutRepositoryLink")

                        Link("Based on iMCP by Mattt", destination: AboutContent.upstreamURL)
                            .accessibilityIdentifier("aboutBasedOnLink")
                    }

                    Button("Report an Issue…") {
                        NSWorkspace.shared.open(AboutContent.reportIssueURL)
                    }
                    .accessibilityIdentifier("aboutReportIssueButton")
                }
                .padding(.top, 12)
            }

            VStack(spacing: 4) {
                if let copyright = content.copyright {
                    Text(copyright)
                        .accessibilityIdentifier("aboutCopyrightText")
                }
                Text(AboutContent.trademark)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aboutTrademarkText")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: 400)
        .padding(24)
    }
}

// prototype: fixture. /implement swaps it for real service calls.
#Preview("About: typical") {
    AboutView(
        content: AboutContent(
            appName: "Pontemac", version: "1.4.0", copyright: "© 2026 Joe Cotellese"))
}

#Preview("About: empty") {
    AboutView(content: AboutContent(appName: "Pontemac", version: nil, copyright: nil))
}

#Preview("About: stress") {
    AboutView(
        content: AboutContent(
            appName: "Pontemac",
            version: "1.4.0 (2026.10.22-beta.12+build.4711)",
            copyright: "© 2026 Joe Cotellese. All rights reserved. Portions © 2025 Mattt."))
}
