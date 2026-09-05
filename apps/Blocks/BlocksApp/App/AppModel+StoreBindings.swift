import AppKit
import BlocksCore
import Combine

// Store subscriptions remain owned by the composition root.
@MainActor
extension AppModel {
    func bindStores(runtimeServicesEnabled: Bool) {
        // Feature views observe their own stores directly. Forwarding every
        // feature mutation through AppModel invalidated the entire main window
        // for clipboard polling, screenshot rendering and unrelated settings.
        // Availability is the only cross-scene state still read from AppModel.
        featureAvailabilityStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        pluginLifecycleSnapshotByID = Dictionary(
            uniqueKeysWithValues: translationPluginManager.plugins.map {
                ($0.id, $0)
            }
        )
        translationPluginManager.$plugins
            .dropFirst()
            .sink { [weak self] plugins in
                guard let self else { return }
                let previous = pluginLifecycleSnapshotByID
                let current = Dictionary(
                    uniqueKeysWithValues: plugins.map { ($0.id, $0) }
                )
                pluginLifecycleSnapshotByID = current
                Task { @MainActor in
                    await self.pluginRuntimeCoordinator.reloadSchedules()
                }
                self.pluginRuntimeCoordinator.dispatchAsync(
                    BlocksPluginEventEnvelope(
                        name: .pluginLifecycleChanged,
                        payload: [
                            "installed_plugin_ids": .array(
                                plugins.map { .string($0.id) }
                            ),
                            "enabled_plugin_ids": .array(
                                plugins.filter(\.isEnabled).map {
                                    .string($0.id)
                                }
                            ),
                            "changes": .array(
                                Self.pluginLifecycleChanges(
                                    previous: previous,
                                    current: current
                                )
                            ),
                        ]
                    )
                )
            }
            .store(in: &cancellables)
        translationPluginManager.$configurationRevision
            .dropFirst()
            .sink { [weak pluginRuntimeCoordinator] revision in
                pluginRuntimeCoordinator?.dispatchAsync(
                    BlocksPluginEventEnvelope(
                        name: .pluginLifecycleChanged,
                        payload: [
                            "operation": .string("configuration_changed"),
                            "configuration_revision": .int(Int(revision)),
                        ]
                    )
                )
            }
            .store(in: &cancellables)
        featureAvailabilityStore.$clipboardEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if runtimeServicesEnabled {
                        self.clipboardCoordinator.loadRepositoryState()
                        self.clipboardCoordinator.startLiveCapture()
                    }
                } else {
                    self.clipboardCoordinator.disableRuntime()
                }
                if runtimeServicesEnabled {
                    self.shortcutStore.setRuntimeAvailability(
                        screenshotEnabled: self.featureAvailabilityStore.screenshotEnabled,
                        clipboardEnabled: enabled
                    )
                }
            }
            .store(in: &cancellables)
        featureAvailabilityStore.$screenshotEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.screenshotCoordinator.disableRuntime()
                }
                if runtimeServicesEnabled {
                    self.shortcutStore.setRuntimeAvailability(
                        screenshotEnabled: enabled,
                        clipboardEnabled: self.featureAvailabilityStore.clipboardEnabled
                    )
                }
            }
            .store(in: &cancellables)
        if runtimeServicesEnabled {
            shortcutStore.setRuntimeAvailability(
                screenshotEnabled: featureAvailabilityStore.screenshotEnabled,
                clipboardEnabled: featureAvailabilityStore.clipboardEnabled
            )
        }
    }

    private static func pluginLifecycleChanges(
        previous: [String: BlocksNativePluginMetadata],
        current: [String: BlocksNativePluginMetadata]
    ) -> [JSONValue] {
        var changes: [JSONValue] = []
        for pluginID in current.keys.sorted() {
            guard let metadata = current[pluginID] else { continue }
            guard let old = previous[pluginID] else {
                changes.append(.object([
                    "plugin_id": .string(pluginID),
                    "operation": .string("installed"),
                ]))
                continue
            }
            var fields: [JSONValue] = []
            if old.packageHash != metadata.packageHash {
                fields.append(.string("package"))
            }
            if old.isEnabled != metadata.isEnabled {
                fields.append(.string("enabled"))
            }
            if old.approvalStatus != metadata.approvalStatus
                || old.approvedPermissions != metadata.approvedPermissions
                || old.approvedDomains != metadata.approvedDomains {
                fields.append(.string("permissions"))
            }
            if old.debugEnabled != metadata.debugEnabled {
                fields.append(.string("debug"))
            }
            if old.safetyDisabled != metadata.safetyDisabled {
                fields.append(.string("safety"))
            }
            if !fields.isEmpty {
                changes.append(.object([
                    "plugin_id": .string(pluginID),
                    "operation": .string("updated"),
                    "changed_fields": .array(fields),
                    "enabled": .bool(metadata.isEnabled),
                    "debug_enabled": .bool(metadata.debugEnabled),
                ]))
            }
        }
        for pluginID in Set(previous.keys).subtracting(current.keys).sorted() {
            changes.append(.object([
                "plugin_id": .string(pluginID),
                "operation": .string("uninstalled"),
            ]))
        }
        return changes
    }
}
