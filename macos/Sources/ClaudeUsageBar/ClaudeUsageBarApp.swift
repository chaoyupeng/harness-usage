import SwiftUI
import AppKit

/// Stands down at launch if another copy of the app is already running, so a
/// build run from the repo does not add a second menu bar icon beside the copy
/// in /Applications. See `SingleInstanceGuard`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SingleInstanceGuard.yieldToExistingInstance() {
            NSApp.terminate(nil)
        }
    }
}

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = UsageService()
    @StateObject private var codexService = CodexUsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()
    @StateObject private var logService = ClaudeLogService()
    @StateObject private var modelCatalog = ModelCatalogService()
    @StateObject private var updateCheck = UpdateCheckService()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                codexService: codexService,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater,
                logService: logService,
                modelCatalog: modelCatalog,
                updateCheck: updateCheck
            )
        } label: {
            Image(nsImage: menuBarImage)
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                    codexService.startPolling()
                    logService.refresh()
                    modelCatalog.refreshIfStale()
                    updateCheck.checkIfDue()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }

    private var menuBarImage: NSImage {
        if codexService.isAvailable {
            if service.isAuthenticated {
                return renderAIUsageIcon(
                    topLabel: "Cl", topPct: service.pct5h,
                    bottomLabel: "Cx", bottomPct: codexService.limits?.primary?.fractionUsed ?? 0
                )
            }
            return renderAIUsageIcon(
                topLabel: codexService.limits?.primary?.shortLabel ?? "1",
                topPct: codexService.limits?.primary?.fractionUsed ?? 0,
                bottomLabel: codexService.limits?.secondary?.shortLabel ?? "2",
                bottomPct: codexService.limits?.secondary?.fractionUsed ?? 0
            )
        }
        return service.isAuthenticated
            ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
            : renderUnauthenticatedIcon()
    }
}
