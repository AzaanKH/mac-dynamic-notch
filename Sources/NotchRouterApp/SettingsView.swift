import AppKit
import SwiftUI

struct SettingsRootView: View {
  @ObservedObject var appDelegate: AppDelegate

  var body: some View {
    Group {
      if let dependencies = appDelegate.settingsDependencies {
        NotchRouterSettingsView(dependencies: dependencies)
      } else {
        VStack(spacing: 12) {
          ProgressView()
          Text("Starting NotchRouter…")
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: 680, height: 540)
  }
}

private struct NotchRouterSettingsView: View {
  let dependencies: SettingsDependencies

  var body: some View {
    TabView {
      GeneralSettingsView(
        launchAtLogin: dependencies.launchAtLogin,
        displaySelection: dependencies.displaySelection,
        activityStore: dependencies.activityStore,
        clipboard: dependencies.clipboard,
        integrations: dependencies.integrations
      )
      .tabItem {
        Label("General", systemImage: "gearshape")
      }

      NotificationSettingsView(service: dependencies.notifications)
        .tabItem {
          Label("Notifications", systemImage: "bell")
        }

      PermissionSettingsView(
        music: dependencies.music,
        clipboard: dependencies.clipboard
      )
      .tabItem {
        Label("Privacy", systemImage: "hand.raised")
      }

      IntegrationSettingsView(
        controller: dependencies.integrations,
        server: dependencies.server
      )
      .tabItem {
        Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted")
      }
    }
    .padding(.top, 8)
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var displaySelection: DisplaySelectionController
  @ObservedObject var activityStore: ActivityStore
  @ObservedObject var clipboard: ClipboardStore
  @ObservedObject var integrations: IntegrationSettingsController

  var body: some View {
    SettingsPage(
      title: "General",
      subtitle: "Choose where NotchRouter appears and how much local history it keeps."
    ) {
      SettingsCard(title: "Startup", symbol: "power") {
        Toggle(
          "Launch NotchRouter at login",
          isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
          )
        )
        .disabled(!launchAtLogin.isAvailable)

        if let message = launchAtLogin.statusMessage {
          SettingsMessage(message, color: .secondary)
          if launchAtLogin.isAvailable {
            Button("Open Login Items Settings") {
              launchAtLogin.openLoginItemsSettings()
            }
            .controlSize(.small)
          }
        }
      }

      SettingsCard(title: "Display", symbol: "display.2") {
        Picker(
          "Position",
          selection: Binding(
            get: { displaySelection.behavior },
            set: { displaySelection.setBehavior($0) }
          )
        ) {
          Text("Follow pointer").tag(DisplayBehavior.pointer)
          Text("Follow active window").tag(DisplayBehavior.activeWindow)
          Text("Pin to a display").tag(DisplayBehavior.pinned)
        }
        .pickerStyle(.menu)

        if displaySelection.behavior == .pinned {
          Picker(
            "Pinned display",
            selection: Binding(
              get: { displaySelection.pinnedDisplayIdentifier },
              set: { displaySelection.setPinnedDisplay($0) }
            )
          ) {
            ForEach(displaySelection.displays) { display in
              Text(
                "\(display.name) · \(display.detail)\(display.isMain ? " · Main" : "")"
              )
              .tag(Optional(display.id))
            }
            if !displaySelection.containsSelectedDisplay() {
              Text("Unavailable display")
                .tag(displaySelection.pinnedDisplayIdentifier)
            }
          }
          .pickerStyle(.menu)
        }

        Toggle(
          "Hide the software notch on external displays",
          isOn: Binding(
            get: { displaySelection.hidesOnExternalDisplays },
            set: { displaySelection.setHidesOnExternalDisplays($0) }
          )
        )

        SettingsMessage(
          displayBehaviorDescription,
          color: .secondary
        )
      }

      SettingsCard(title: "Local history", symbol: "clock.arrow.circlepath") {
        Picker(
          "Activity entries",
          selection: Binding(
            get: { activityStore.retentionLimit },
            set: { activityStore.setRetentionLimit($0) }
          )
        ) {
          ForEach(activityRetentionOptions, id: \.self) { count in
            Text("\(count) entries").tag(count)
          }
        }
        .pickerStyle(.menu)

        Picker(
          "Clipboard entries",
          selection: Binding(
            get: { clipboard.retentionLimit },
            set: { clipboard.setRetentionLimit($0) }
          )
        ) {
          ForEach(clipboardRetentionOptions, id: \.self) { count in
            Text("\(count) entries").tag(count)
          }
        }
        .pickerStyle(.menu)

        Picker(
          "Auto-delete unpinned clips",
          selection: Binding(
            get: { clipboard.autoExpiry },
            set: { clipboard.setAutoExpiry($0) }
          )
        ) {
          ForEach(ClipboardAutoExpiry.allCases) { expiry in
            Text(expiry.title).tag(expiry)
          }
        }
        .pickerStyle(.menu)

        SettingsMessage(
          "Pinned clips are kept outside the entry limit and never expire automatically. Clipboard image files are removed with their entries.",
          color: .secondary
        )

        Button("Open Data Folder") {
          integrations.openDataFolder()
        }
        .controlSize(.small)
      }
    }
  }

  private var activityRetentionOptions: [Int] {
    Array(
      Set(ActivityStore.availableRetentionLimits + [activityStore.retentionLimit])
    ).sorted()
  }

  private var clipboardRetentionOptions: [Int] {
    Array(
      Set(ClipboardStore.availableRetentionLimits + [clipboard.retentionLimit])
    ).sorted()
  }

  private var displayBehaviorDescription: String {
    switch displaySelection.behavior {
    case .pointer:
      "The notch follows the display containing the pointer."
    case .activeWindow:
      "The notch follows the frontmost window as you work across displays."
    case .pinned:
      "The notch stays on the pinned display across spaces and full-screen apps."
    }
  }
}

private struct NotificationSettingsView: View {
  @ObservedObject var service: ActivityNotificationService

  var body: some View {
    SettingsPage(
      title: "Notifications",
      subtitle: "Choose which events can alert you outside the notch."
    ) {
      SettingsCard(title: "System notifications", symbol: "bell.badge") {
        HStack {
          Toggle(
            "Allow system notifications",
            isOn: Binding(
              get: { service.isEnabled },
              set: { service.setEnabled($0) }
            )
          )
          Spacer()
          if service.isRequestingAuthorization {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let message = service.permissionMessage {
          SettingsMessage(message, color: .orange)
        }

        Button("Open Notification Settings") {
          openSystemSettings(
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
          )
        }
        .controlSize(.small)
      }

      SettingsCard(title: "Notify me about", symbol: "checklist") {
        ForEach(ActivityNotificationKind.allCases) { kind in
          VStack(alignment: .leading, spacing: 3) {
            Toggle(
              kind.title,
              isOn: Binding(
                get: { service.isEnabled(for: kind) },
                set: { service.setEnabled($0, for: kind) }
              )
            )
            Text(kind.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 20)
          }
        }
        .disabled(!service.isEnabled)

        SettingsMessage(
          "Queued, running, stale, and cancelled updates stay in the notch without generating a system notification.",
          color: .secondary
        )
      }

      SettingsCard(title: "Focus timer", symbol: "timer") {
        VStack(alignment: .leading, spacing: 3) {
          Toggle(
            "Show a notification when focus completes",
            isOn: Binding(
              get: { service.focusCompletionNotificationsEnabled },
              set: { service.setFocusCompletionNotificationsEnabled($0) }
            )
          )
          .disabled(!service.isEnabled)

          Text("Uses the system notification permission above.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
        }

        VStack(alignment: .leading, spacing: 3) {
          Toggle(
            "Play a sound when focus completes",
            isOn: Binding(
              get: { service.focusCompletionSoundEnabled },
              set: { service.setFocusCompletionSoundEnabled($0) }
            )
          )

          Text("The sound can play even when system notifications are off.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
        }

        SettingsMessage(
          "The notch still peeks at completion whether or not these alerts are enabled.",
          color: .secondary
        )
      }
    }
  }
}

private struct PermissionSettingsView: View {
  @ObservedObject var music: MusicController
  @ObservedObject var clipboard: ClipboardStore

  var body: some View {
    SettingsPage(
      title: "Privacy",
      subtitle: "Music, browser media, and clipboard access remain opt-in."
    ) {
      SettingsCard(title: "Music controls", symbol: "music.note") {
        Toggle(
          "Control Apple Music and Spotify",
          isOn: Binding(
            get: { music.isEnabled },
            set: { music.setEnabled($0) }
          )
        )

        SettingsMessage(
          "NotchRouter reads the current track and sends playback commands. macOS may ask for Automation access when a running music app is first queried.",
          color: .secondary
        )

        if let message = music.permissionMessage {
          SettingsMessage(message, color: .orange)
        }

        HStack {
          Button("Open Automation Settings") {
            openSystemSettings(
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
          }
          Button("Check Again") {
            music.refresh(allowsPermissionPrompt: true)
          }
          .disabled(!music.isEnabled)
        }
        .controlSize(.small)
      }

      SettingsCard(title: "Clipboard history", symbol: "list.clipboard") {
        Toggle(
          "Capture copied text and images",
          isOn: Binding(
            get: { clipboard.isEnabled },
            set: { clipboard.setEnabled($0) }
          )
        )

        SettingsMessage(
          "New copies are stored only on this Mac. Concealed, transient, auto-generated, known password-manager, and app-excluded pasteboards are ignored before content is read.",
          color: .secondary
        )

        Divider()

        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Excluded apps")
              .fontWeight(.medium)
            Text("Future copies from these apps are ignored.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Exclude Apps…") {
            clipboard.chooseApplicationsToExclude()
          }
          .controlSize(.small)
        }

        if clipboard.excludedApplications.isEmpty {
          Text("No apps excluded")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(spacing: 6) {
              ForEach(clipboard.excludedApplications) { application in
                HStack(spacing: 8) {
                  Image(nsImage: clipboard.icon(for: application))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(application.name)
                      .lineLimit(1)
                    Text(application.bundleIdentifier)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  Spacer()
                  Button {
                    clipboard.removeExcludedApplication(
                      application.bundleIdentifier
                    )
                  } label: {
                    Image(systemName: "xmark")
                  }
                  .buttonStyle(.borderless)
                  .accessibilityLabel("Stop excluding \(application.name)")
                }
              }
            }
          }
          .frame(maxHeight: 92)
        }

        HStack {
          Text("\(clipboard.entries.count) saved")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Clear Clipboard History", role: .destructive) {
            clipboard.clear()
          }
          .disabled(clipboard.entries.isEmpty)
        }
        .controlSize(.small)
      }
    }
  }
}

private struct IntegrationSettingsView: View {
  @ObservedObject var controller: IntegrationSettingsController
  @ObservedObject var server: ActivityHTTPServer

  @State private var revealsToken = false
  @State private var confirmsRotation = false

  var body: some View {
    SettingsPage(
      title: "Integrations",
      subtitle: "Connect local agents and supported browser media."
    ) {
      SettingsCard(title: "Local activity server", symbol: "network") {
        HStack(spacing: 8) {
          Circle()
            .fill(serverStatusColor)
            .frame(width: 8, height: 8)
          Text(serverStatusLabel)
            .fontWeight(.medium)
          Spacer()
          if server.state.canRetry {
            Button("Retry") {
              controller.retryServer()
            }
            .controlSize(.small)
          }
        }

        LabeledContent("Endpoint") {
          Text(controller.endpoint)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }

        HStack {
          Button("Copy Endpoint") {
            controller.copyEndpoint()
          }
          Button("Copy Example Request") {
            controller.copyExampleRequest()
          }
        }
        .controlSize(.small)
      }

      SettingsCard(title: "Authentication token", symbol: "key") {
        HStack(spacing: 10) {
          Group {
            if revealsToken {
              Text(controller.token)
                .textSelection(.enabled)
            } else {
              Text(maskedToken)
            }
          }
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
          Spacer()
          Button(revealsToken ? "Hide" : "Reveal") {
            revealsToken.toggle()
          }
          .controlSize(.small)
        }

        HStack {
          Button("Copy Token") {
            controller.copyToken()
          }
          Button("Rotate Token…", role: .destructive) {
            confirmsRotation = true
          }
        }
        .controlSize(.small)

        SettingsMessage(
          "The token is stored with user-only file permissions. Rotating it immediately rejects the old token.",
          color: .secondary
        )
      }

      SettingsCard(title: "Codex and T3 Code", symbol: "terminal") {
        HStack(spacing: 8) {
          Image(
            systemName: controller.codexHooksInstalled
              ? "checkmark.circle.fill"
              : "circle.dashed"
          )
          .foregroundStyle(controller.codexHooksInstalled ? .green : .secondary)
          Text(
            controller.codexHooksInstalled
              ? "Lifecycle hooks are installed"
              : "Lifecycle hooks are not installed"
          )
          Spacer()
          if controller.isRunningCodexSetup {
            ProgressView()
              .controlSize(.small)
          }
        }

        SettingsMessage(
          "The adapter publishes activity IDs, workspace names, and lifecycle states. It does not send prompts, source code, tool output, or responses.",
          color: .secondary
        )

        HStack {
          Button(controller.codexHooksInstalled ? "Reinstall Hooks" : "Install Hooks") {
            controller.installCodexHooks()
          }
          Button("Remove Hooks") {
            controller.removeCodexHooks()
          }
          .disabled(!controller.codexHooksInstalled)
        }
        .controlSize(.small)
        .disabled(controller.isRunningCodexSetup)

        if let message = controller.operationMessage {
          SettingsMessage(message, color: .secondary)
        }
      }

      SettingsCard(title: "Browser media", symbol: "play.rectangle.on.rectangle") {
        HStack(spacing: 8) {
          Image(
            systemName: controller.browserExtensionInstalled
              ? "checkmark.circle.fill"
              : "circle.dashed"
          )
          .foregroundStyle(
            controller.browserExtensionInstalled ? .green : .secondary
          )
          Text(
            controller.browserExtensionInstalled
              ? "Native browser bridge is installed"
              : "Browser bridge is not installed"
          )
          Spacer()
          if controller.isRunningBrowserSetup {
            ProgressView()
              .controlSize(.small)
          }
        }

        SettingsMessage(
          "Supports Chrome, Edge, Brave, and Chromium. Active media metadata stays on this Mac; the extension cannot read the local API token.",
          color: .secondary
        )

        if controller.browserExtensionInstalled {
          Text(
            "Turn on Developer mode, choose Load unpacked, then select the installed extension folder."
          )
          .font(.caption.weight(.medium))

          HStack {
            Button("Open Extensions Page") {
              controller.openBrowserExtensionManager()
            }
            Button("Open Extension Folder") {
              controller.openBrowserExtensionFolder()
            }
            Button("Reinstall Bridge") {
              controller.installBrowserExtension()
            }
          }
          .controlSize(.small)

          Button("Remove Browser Bridge", role: .destructive) {
            controller.removeBrowserExtension()
          }
          .controlSize(.small)
        } else {
          Button("Install Browser Bridge") {
            controller.installBrowserExtension()
          }
          .controlSize(.small)
        }

        if let message = controller.browserOperationMessage {
          SettingsMessage(message, color: .secondary)
        }
      }
    }
    .confirmationDialog(
      "Rotate the integration token?",
      isPresented: $confirmsRotation,
      titleVisibility: .visible
    ) {
      Button("Rotate and Copy New Token", role: .destructive) {
        controller.rotateToken()
        revealsToken = false
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Existing third-party clients will stop working until they use the new token. The bundled CLI and Codex adapter read the updated token automatically."
      )
    }
  }

  private var maskedToken: String {
    String(repeating: "•", count: 32)
  }

  private var serverStatusLabel: String {
    switch server.state {
    case .stopped: "Stopped"
    case .starting: "Starting on port \(server.port)…"
    case .ready: "Listening on 127.0.0.1:\(server.port)"
    case .failed(let failure): failure.message
    }
  }

  private var serverStatusColor: Color {
    switch server.state {
    case .ready: .green
    case .starting: .orange
    case .stopped, .failed: .red
    }
  }
}

private struct SettingsPage<Content: View>: View {
  let title: String
  let subtitle: String
  let content: Content

  init(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.title2.weight(.semibold))
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }
}

private struct SettingsCard<Content: View>: View {
  let title: String
  let symbol: String
  let content: Content

  init(
    title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 11) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 3)
    } label: {
      Label(title, systemImage: symbol)
        .font(.headline)
    }
  }
}

private struct SettingsMessage: View {
  let message: String
  let color: Color

  init(_ message: String, color: Color) {
    self.message = message
    self.color = color
  }

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private func openSystemSettings(_ address: String) {
  guard let url = URL(string: address) else { return }
  NSWorkspace.shared.open(url)
}
