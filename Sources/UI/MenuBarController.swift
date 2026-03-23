import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: ProviderStore
    private var cancellables = Set<AnyCancellable>()
    private var mergedItem: NSStatusItem?
    private var providerItems: [ProviderKind: NSStatusItem] = [:]
    private var handlers: [String: StatusItemActionHandler] = [:]
    private let popover = NSPopover()
    private weak var activeButton: NSStatusBarButton?

    init(store: ProviderStore) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        bind()
        rebuildStatusItems()
    }

    func popoverDidClose(_ notification: Notification) {
        activeButton = nil
    }

    private func bind() {
        Publishers.CombineLatest(store.$snapshots, store.settingsStore.$settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.rebuildStatusItems()
            }
            .store(in: &cancellables)
    }

    private func rebuildStatusItems() {
        switch store.settingsStore.settings.barDisplayMode {
        case .merged:
            installMergedItem()
            removeSeparateItems()
        case .separate:
            if enabledProviders.isEmpty {
                installMergedItem()
                removeSeparateItems()
            } else {
                removeMergedItem()
                installSeparateItems()
            }
        }
    }

    private func installMergedItem() {
        let item = mergedItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mergedItem = item

        let enabledSnapshots = enabledProviders.map { store.snapshot(for: $0) }
        let snapshots = enabledSnapshots.isEmpty ? ProviderKind.allCases.map { store.snapshot(for: $0) } : enabledSnapshots
        item.button?.image = StatusIconRenderer.mergedIcon(snapshots: snapshots)
        item.button?.toolTip = "AI Usage Tracker"
        attachHandler(to: item, key: "merged", provider: nil)
    }

    private func installSeparateItems() {
        let enabledProviders = self.enabledProviders

        for provider in enabledProviders {
            let item = providerItems[provider] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            providerItems[provider] = item
            item.button?.image = StatusIconRenderer.separateIcon(for: provider, snapshot: store.snapshot(for: provider))
            item.button?.toolTip = provider.displayName
            attachHandler(to: item, key: provider.rawValue, provider: provider)
        }

        let staleProviders = providerItems.keys.filter { !enabledProviders.contains($0) }
        for provider in staleProviders {
            if let item = providerItems.removeValue(forKey: provider) {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
    }

    private func attachHandler(to item: NSStatusItem, key: String, provider: ProviderKind?) {
        let handler = StatusItemActionHandler(controller: self, provider: provider)
        handlers[key] = handler
        item.button?.target = handler
        item.button?.action = #selector(StatusItemActionHandler.handleClick(_:))
    }

    private func removeMergedItem() {
        if let mergedItem {
            NSStatusBar.system.removeStatusItem(mergedItem)
            self.mergedItem = nil
        }
        handlers.removeValue(forKey: "merged")
    }

    private func removeSeparateItems() {
        providerItems.values.forEach { NSStatusBar.system.removeStatusItem($0) }
        providerItems.removeAll()
        handlers = handlers.filter { $0.key == "merged" }
    }

    fileprivate func togglePopover(relativeTo button: NSStatusBarButton, provider: ProviderKind?) {
        if popover.isShown, activeButton === button {
            popover.performClose(nil)
            return
        }

        activeButton = button
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: RootPopoverView(
                store: store,
                initialProvider: provider ?? enabledProviders.first
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private var enabledProviders: [ProviderKind] {
        store.settingsStore.settings.enabledProviders
    }
}

@MainActor
private final class StatusItemActionHandler: NSObject {
    private weak var controller: MenuBarController?
    private let provider: ProviderKind?

    init(controller: MenuBarController, provider: ProviderKind?) {
        self.controller = controller
        self.provider = provider
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        controller?.togglePopover(relativeTo: sender, provider: provider)
    }
}
