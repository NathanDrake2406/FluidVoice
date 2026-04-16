import AppKit
import SwiftUI

struct MCPSettingsEditorView: View {
    @ObservedObject var service: CommandModeService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var originalText: String = ""
    @State private var draftText: String = ""
    @State private var settingsPath: String = ""
    @State private var statusMessage: String = "Loading settings.json..."
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isReloadingFromDisk = false
    @State private var isValidating = false
    @State private var isSaving = false
    @State private var showingDiscardConfirmation = false

    private var hasUnsavedChanges: Bool {
        self.draftText != self.originalText
    }

    private var isBusy: Bool {
        self.isLoading || self.isReloadingFromDisk || self.isValidating || self.isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Edit MCP settings.json")
                    .font(.headline)

                if self.hasUnsavedChanges {
                    Text("Unsaved")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }

                Spacer()
            }

            Text(self.settingsPath.isEmpty ? "Path unavailable" : self.settingsPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            Text("Save validates JSON and auto-reloads MCP servers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            self.feedbackBanner

            Group {
                if self.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading settings.json...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PromptTextView(
                        text: self.$draftText,
                        isEditable: !self.isBusy,
                        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        contentInset: 12
                    )
                    .frame(minHeight: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(self.theme.palette.contentBackground.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                            )
                    )
                }
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    self.handleDismissRequest()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(self.isReloadingFromDisk ? "Reloading..." : "Reload From Disk") {
                    Task { await self.reloadFromDisk() }
                }
                .buttonStyle(.bordered)
                .disabled(self.isBusy)

                Button(self.isValidating ? "Validating..." : "Validate") {
                    Task { await self.validateDraft() }
                }
                .buttonStyle(.bordered)
                .disabled(self.isBusy)

                Button(self.isSaving ? "Saving..." : "Save & Reload MCP") {
                    Task { await self.saveDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.isBusy || !self.hasUnsavedChanges)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .background(self.theme.palette.windowBackground)
        .task {
            await self.loadInitialState()
        }
        .interactiveDismissDisabled(self.hasUnsavedChanges || self.isBusy)
        .confirmationDialog(
            "Discard unsaved MCP changes?",
            isPresented: self.$showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                self.dismiss()
            }
            Button("Continue Editing", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let errorMessage, !errorMessage.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(self.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.contentBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }

    private func handleDismissRequest() {
        if self.hasUnsavedChanges {
            self.showingDiscardConfirmation = true
        } else {
            self.dismiss()
        }
    }

    @MainActor
    private func loadInitialState() async {
        guard self.isLoading else { return }
        self.errorMessage = nil
        self.statusMessage = "Loading settings.json..."

        do {
            let json = try await self.service.loadMCPSettingsJSON()
            let fileURL = await self.service.mcpSettingsFileURL()

            self.settingsPath = fileURL?.path ?? ""
            self.draftText = json
            self.originalText = json
            self.statusMessage = "Loaded settings.json."
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Could not load settings.json."
        }

        self.isLoading = false
    }

    @MainActor
    private func reloadFromDisk() async {
        guard !self.isBusy else { return }

        self.isReloadingFromDisk = true
        self.errorMessage = nil
        self.statusMessage = "Reloading settings.json from disk..."

        do {
            let json = try await self.service.loadMCPSettingsJSON()
            let fileURL = await self.service.mcpSettingsFileURL()

            if let fileURL {
                self.settingsPath = fileURL.path
            }
            self.draftText = json
            self.originalText = json
            self.statusMessage = "Reloaded settings.json from disk."
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Reload failed."
        }

        self.isReloadingFromDisk = false
    }

    @MainActor
    private func validateDraft() async {
        guard !self.isBusy else { return }

        self.isValidating = true
        self.errorMessage = nil
        self.statusMessage = "Validating settings.json..."

        do {
            try await self.service.validateMCPSettingsJSON(self.draftText)
            self.statusMessage = "Validation passed."
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Validation failed."
        }

        self.isValidating = false
    }

    @MainActor
    private func saveDraft() async {
        guard !self.isBusy else { return }

        self.isSaving = true
        self.errorMessage = nil
        self.statusMessage = "Saving settings.json and reloading MCP..."

        do {
            try await self.service.saveMCPSettingsJSONAndReload(self.draftText)
            self.originalText = self.draftText
            self.statusMessage = "Saved settings.json and reloaded MCP."
        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Save failed."
        }

        self.isSaving = false
    }
}
