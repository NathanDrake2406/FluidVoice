import SwiftUI

struct AIEnhancementSettingsView: View {
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var promptTest: DictationPromptTestCoordinator
    let theme: AppTheme
    @State var expandedProviderID: String? = nil
    @State var providerSearchText: String = ""
    @State var fluid1InterestEmail: String = ""
    @State var fluid1InterestErrorMessage: String = ""
    @State var fluid1InterestIsSubmitting: Bool = false
    @State var hoveredPromptCardKey: String? = nil

    var body: some View {
        self.aiConfigurationCard
            .onAppear {
                self.viewModel.onAppear()
            }
            .onChange(of: self.viewModel.connectionStatus) { oldValue, newValue in
                if oldValue == .success && newValue != .success {
                    self.expandedProviderID = self.viewModel.selectedProviderID
                }
            }
            .onChange(of: self.viewModel.showKeychainPermissionAlert) { _, isPresented in
                guard isPresented else { return }
                self.viewModel.presentKeychainAccessAlert(message: self.viewModel.keychainPermissionMessage)
                self.viewModel.showKeychainPermissionAlert = false
            }
            .alert("Delete Prompt?", isPresented: self.$viewModel.showingDeletePromptConfirm) {
                Button("Delete", role: .destructive) {
                    self.viewModel.deletePendingPrompt()
                }
                Button("Cancel", role: .cancel) {
                    self.viewModel.clearPendingDeletePrompt()
                }
            } message: {
                if self.viewModel.pendingDeletePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This cannot be undone.")
                } else {
                    Text("Delete “\(self.viewModel.pendingDeletePromptName)”? This cannot be undone.")
                }
            }
    }
}
