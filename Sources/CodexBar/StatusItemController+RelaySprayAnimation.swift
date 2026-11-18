import Foundation

extension StatusItemController {
    func startCodexActivityPulseMonitoring() {
        guard self.codexActivityPulseMonitor == nil else { return }
        let sessionsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .path
        let monitor = CodexActivityPulseMonitor(path: sessionsPath) { [weak self] in
            self?.noteCodexOutputActivity()
        }
        guard monitor.start() else { return }
        self.codexActivityPulseMonitor = monitor
    }

    func noteCodexOutputActivity(now: Date = Date()) {
        guard self.settings.menuBarShowsBrandIconWithPercent,
              RelaySprayAnimation.shouldAnimate(
                  isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                  thermalState: ProcessInfo.processInfo.thermalState)
        else {
            self.stopRelaySprayAnimation(restoreRestingIcon: true)
            return
        }

        self.relaySprayActiveUntil = now.addingTimeInterval(RelaySprayAnimation.activeTail)
        guard self.relaySprayTask == nil else { return }

        self.relaySprayTick = 0
        self.relaySprayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let activeUntil = self.relaySprayActiveUntil,
                      activeUntil > Date()
                else {
                    self.stopRelaySprayAnimation(restoreRestingIcon: true)
                    return
                }

                self.relaySprayFrame = RelaySprayAnimation.frame(forTick: self.relaySprayTick)
                self.relaySprayTick += 1
                self.applyIcon(phase: nil)
                try? await Task.sleep(
                    for: .milliseconds(1000 / RelaySprayAnimation.framesPerSecond))
            }
        }
    }

    func stopRelaySprayAnimation(restoreRestingIcon: Bool) {
        let hadAnimation = self.relaySprayTask != nil || self.relaySprayFrame != nil
        self.relaySprayTask?.cancel()
        self.relaySprayTask = nil
        self.relaySprayActiveUntil = nil
        self.relaySprayFrame = nil
        self.relaySprayTick = 0
        if restoreRestingIcon, hadAnimation {
            self.applyIcon(phase: nil)
        }
    }
}
