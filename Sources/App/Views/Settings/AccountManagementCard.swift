import SwiftUI
import AppKit
import Domain

/// Settings card for managing accounts on a multi-account provider.
///
/// Shows the list of configured accounts with options to add, remove,
/// and set the active account. Only rendered for providers that conform
/// to `MultiAccountProvider`.
struct AccountManagementCard: View {
    let provider: any MultiAccountProvider
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var isExpanded = false
    @State private var showAddSheet = false
    @State private var newAccountLabel = ""
    @State private var newConfigDirectory = ""
    @State private var addAccountError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 8)

            VStack(spacing: 8) {
                ForEach(provider.accounts, id: \.id) { account in
                    accountRow(account)
                }

                addAccountButton
            }
        } label: {
            header
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .fill(theme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
        )
        .sheet(isPresented: $showAddSheet) {
            addAccountSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.accentGradient)
                    .frame(width: 32, height: 32)

                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Accounts")
                    .font(.system(size: 14, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Text("\(provider.accounts.count) account\(provider.accounts.count == 1 ? "" : "s") configured")
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()

            // Aggregate status badge
            let statusColor = theme.statusColor(for: provider.aggregateStatus)
            Text(provider.aggregateStatus.badgeText)
                .badge(statusColor)
        }
    }

    // MARK: - Account Row

    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        account.accountId == provider.activeAccount.accountId
                            ? theme.accentPrimary
                            : theme.glassBackground
                    )
                    .frame(width: 24, height: 24)

                Text(account.initialLetter)
                    .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(
                        account.accountId == provider.activeAccount.accountId
                            ? .white
                            : theme.textSecondary
                    )
            }

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if let email = account.email {
                    Text(email)
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Status from snapshot
            if let snapshot = provider.accountSnapshots[account.accountId] {
                let status = snapshot.overallStatus
                Circle()
                    .fill(theme.statusColor(for: status))
                    .frame(width: 8, height: 8)
            }

            // Active indicator
            if account.accountId == provider.activeAccount.accountId {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.statusHealthy)
            } else {
                // Switch button
                Button {
                    provider.switchAccount(to: account.accountId)
                    Task {
                        await monitor.refresh(providerId: provider.id)
                    }
                } label: {
                    Text("Switch")
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.accentPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .stroke(theme.accentPrimary.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if !account.isDefault, let claudeProvider = provider as? ClaudeProvider {
                Button {
                    claudeProvider.removeAccount(accountId: account.accountId)
                    Task {
                        await monitor.refresh(providerId: provider.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.statusCritical)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Remove account")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Add Account

    private var addAccountButton: some View {
        Button {
            resetAddForm()
            showAddSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))

                Text("Add Account")
                    .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
            }
            .foregroundStyle(theme.accentPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.accentPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(!(provider is ClaudeProvider))
        .opacity(provider is ClaudeProvider ? 1 : 0.6)
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Claude Account")
                    .font(.system(size: 15, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Button {
                    showAddSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("LABEL")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                TextField("Work", text: $newAccountLabel)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CLAUDE CONFIG DIRECTORY")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                HStack(spacing: 8) {
                    TextField("~/.claude-profiles/work", text: $newConfigDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        chooseConfigDirectory()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .help("Choose folder")
                }
            }

            if let addAccountError {
                Text(addAccountError)
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.statusCritical)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    showAddSheet = false
                }

                Button("Add") {
                    addClaudeAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newConfigDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(theme.backgroundGradient)
    }

    private func resetAddForm() {
        newAccountLabel = ""
        newConfigDirectory = ""
        addAccountError = nil
    }

    private func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            newConfigDirectory = url.path
        }
    }

    private func addClaudeAccount() {
        guard let claudeProvider = provider as? ClaudeProvider else {
            addAccountError = "This provider does not support adding accounts yet."
            return
        }

        let added = claudeProvider.addCLIAccount(
            label: newAccountLabel,
            configDirectoryPath: newConfigDirectory
        )
        guard added else {
            addAccountError = "Enter a Claude config directory."
            return
        }

        showAddSheet = false
        Task {
            await monitor.refresh(providerId: provider.id)
        }
    }
}
