import Cocoa

// Reads ~/.codex/statusbar/state.json (written by Codex hooks) and renders a
// Codex "prompt" mark + short status label in the macOS menu bar. No window, no dock icon.

private struct GeorgeLightColorSelection {
    let state: LightState
    let color: String
}

private struct GeorgeLightModeSelection {
    let state: LightState
    let mode: GeorgeLightMode
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let lightOutput: ConfigurableLightOutput
    var georgeLightConfiguration: GeorgeLightConfiguration
    var agentConfiguration: AgentProviderConfiguration
    let codexStatesDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/states.d")
    let claudeStatesDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/states.d")
    let legacyStatePath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/state.json")
    let codexSessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/sessions.d")
    let claudeSessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/sessions.d")
    // provider + filename -> state and observed mtime.
    var sessions: [String: (state: SessionState, mtime: Date)] = [:]
    var pinnedSession: String?
    var pinnedDiedAt: Date?   // when the pinned session went stale; grey it for 5s before dropping
    var terminalShownAt: [String: Date] = [:] // per-session Done/Error dismiss clocks
    var timeoutLogged: Set<String> = []    // sessionIds already logged as timed out (dedupe per stuck episode)

    var lastMTime: Date = .distantPast
    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0
    let hookInstallerQueue = DispatchQueue(label: "io.github.georgebin.intelli-light.hook-installer")

    // Self-quit lifecycle: we're launched by the session-start hook; we decide when to
    // leave (see checkLifecycle). No background/login item — the check only runs while
    // we're already alive.
    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    let freshWindow: TimeInterval = 20  // a session file touched this recently counts as active

    var activeBase = ""        // label without the elapsed clock
    var activeStartedAt: TimeInterval = 0
    var activePausedTotal: TimeInterval = 0
    var activePauseStart: TimeInterval = 0
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.30, green: 0.56, blue: 1.00, alpha: 1) // #4D8FFF accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let errorRed = NSColor(srgbRed: 1.00, green: 0.00, blue: 0.00, alpha: 1)
    let frames: [NSImage] = StatusController.loadFrames() // prompt morph masks
    let spriteFPS: Double = 9 // tune: frames per loop -> ~0.9s/cycle

    var showTimer = true
    var iconSystem = false // false = brand accent; true = adaptive black/white (template image)
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    var fps: Double { spriteFPS }
    var frameCount: Int { max(1, frames.count) }

    override init() {
        let georgeLight = GeorgeLightConfiguration()
        agentConfiguration = AgentProviderConfiguration()
        georgeLightConfiguration = georgeLight
        lightOutput = GeorgeLightHttpOutput(
            baseURL: georgeLight.baseURL, enabled: georgeLight.enabled, effects: georgeLight.effects)
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if let p = d.string(forKey: "pinnedSession"), !p.isEmpty { pinnedSession = p }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensureHooksInstalled()
    }

    // Wire up the Codex and Claude Code hooks ourselves by running the bundled installer, so the
    // user just drags the app in and opens it — no manual Terminal step. Runs on first
    // install AND whenever the version or bundled hook resources change, so upgrades pick
    // up new/changed hooks and retire old artifacts. install.js is idempotent.
    func ensureHooksInstalled(force: Bool = false) {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        let providers = agentConfiguration.enabledProviders
        let fingerprint = "\(current)|\(installerProviderArgument(providers))|\(hookInstallFingerprint(installer: installer))"
        guard force || d.string(forKey: "installedHookFingerprint") != fingerprint else { return }
        hookInstallerQueue.async { [weak self] in
            let config = installerLaunchConfiguration(installer: installer, providers: providers)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: config.executablePath)
            task.arguments = config.arguments
            task.environment = config.environment
            var installed = false
            do { try task.run(); task.waitUntilExit(); installed = task.terminationStatus == 0 } catch {}
            if installed {
                UserDefaults.standard.set(fingerprint, forKey: "installedHookFingerprint")
            } else {
                self?.showInstallerFailure(installer: installer, providers: providers)
            }
        }
    }

    func showInstallerFailure(installer: String, providers: Set<AgentProvider>) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Intelli Light could not set up its agent hooks"
            let providerArgument = installerProviderArgument(providers)
            alert.informativeText = "The selected agent hooks weren’t configured — Node.js may not be on the app’s PATH. Open Terminal and run:\n\nnode \(shellQuoted(installer)) \(shellQuoted(providerArgument))\n\nThen restart the agent."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func hookInstallFingerprint(installer: String) -> String {
        let resourceDir = (installer as NSString).deletingLastPathComponent
        let names = ["install.js", "update.js", "lifecycle.js", "claude-update.js",
                     "claude-lifecycle.js", "uninstall.js", "fs-utils.js"]
        return names.map { name in
            let path = (resourceDir as NSString).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else {
                return "\(name):missing"
            }
            let modifiedAt = String(format: "%.6f", modified.timeIntervalSince1970)
            return "\(name):\(size.int64Value):\(modifiedAt)"
        }.joined(separator: "|")
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        appendSessionsMenu(into: menu)

        menu.addItem(.separator())

        let timerItem = NSMenuItem(title: "Show timer", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        let agentsItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let agentsMenu = NSMenu(title: "Agents")
        for provider in AgentProvider.allCases {
            let item = NSMenuItem(title: provider == .claude ? "Claude Code" : provider.displayName,
                                  action: #selector(toggleAgentProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = agentConfiguration.enabledProviders.contains(provider) ? .on : .off
            item.isEnabled = item.state == .off || agentConfiguration.enabledProviders.count > 1
            agentsMenu.addItem(item)
        }
        agentsItem.submenu = agentsMenu
        menu.addItem(agentsItem)

        menu.addItem(.separator())
        let georgeLightItem = NSMenuItem(title: "Enable GeorgeLight",
                                         action: #selector(toggleGeorgeLight), keyEquivalent: "")
        georgeLightItem.target = self
        georgeLightItem.state = georgeLightConfiguration.enabled ? .on : .off
        menu.addItem(georgeLightItem)

        let addressItem = NSMenuItem(title: "Address...",
                                     action: #selector(setGeorgeLightAddress), keyEquivalent: "")
        addressItem.target = self
        menu.addItem(addressItem)

        for state in [LightState.working, .actionRequired, .error, .done] {
            menu.addItem(georgeLightEffectMenuItem(for: state))
        }

        menu.addItem(.separator())
        for (sys, name) in [(false, "Accent"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Intelli Light", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func appendSessionsMenu(into menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let all = sessions.map { $0.value.state }.filter {
            agentConfiguration.enabledProviders.contains($0.provider)
        }
        let live = all.filter { displayEligible($0, now: now) }
        let ordered = menuOrder(pinned: pinnedSession, sessions: live, now: now, limit: 5)

        // Track pinned death so the pinned item can be greyed for 5s before dropping.
        let pinnedAlive = live.first(where: { pinnedSessionMatches(pinnedSession, $0) })?.isAlive(now: now) ?? false
        if pinnedSession != nil, !pinnedAlive {
            if pinnedDiedAt == nil { pinnedDiedAt = Date() }
            if let died = pinnedDiedAt, Date().timeIntervalSince(died) > 5 {
                pinnedSession = nil; pinnedDiedAt = nil
                UserDefaults.standard.removeObject(forKey: "pinnedSession")
            }
        } else {
            pinnedDiedAt = nil
        }

        var endedState: SessionState?
        if let p = pinnedSession, !pinnedAlive, let died = pinnedDiedAt,
           Date().timeIntervalSince(died) <= 5 {
            endedState = all.first(where: { pinnedSessionMatches(p, $0) })
        }

        if ordered.isEmpty {
            if let st = endedState {
                menu.addItem(.separator())
                menu.addItem(endedMenuItem(for: st))
                menu.addItem(.separator())
            }
            return
        }
        if let st = endedState {
            menu.addItem(.separator())
            menu.addItem(endedMenuItem(for: st))
        }
        menu.addItem(.separator())
        for st in ordered {
            let isPinned = pinnedSessionMatches(pinnedSession, st)
            let status = st.normalizedState.menuTitle
            let title = "\(isPinned ? "● " : "")\(st.provider.displayName) · \(st.project.isEmpty ? st.sessionId : st.project) · \(status)"
            let item = NSMenuItem(title: title, action: #selector(pinSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = st.key.persistedValue
            item.state = isPinned ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    func endedMenuItem(for st: SessionState) -> NSMenuItem {
        let title = "● \(st.provider.displayName) · \(st.project.isEmpty ? st.sessionId : st.project) · ended"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func pinSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        pinnedSession = (pinnedSession == id) ? nil : id
        pinnedDiedAt = nil
        UserDefaults.standard.set(pinnedSession, forKey: "pinnedSession")
        evaluate()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // Prefer the Codex desktop app if it's installed; otherwise fall back to running
    // `codex` in Terminal.app. The app is looked up by bundle id via LaunchServices so
    // it's found no matter where it lives (/Applications, ~/Applications, …). Only
    // Terminal.app answers AppleScript's "do script" event (Ghostty/iTerm2 don't), so
    // the fallback stays Terminal-only.
    @objc func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e", "tell application \"Terminal\" to do script \"codex\"",
            "-e", "tell application \"Terminal\" to activate",
        ]
        try? task.run()
    }

    @objc func toggleTimer() {
        showTimer.toggle()
        UserDefaults.standard.set(showTimer, forKey: "showTimer")
        applyTitle()
    }

    @objc func toggleAgentProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = AgentProvider(rawValue: raw),
              agentConfiguration.toggle(provider) else {
            NSSound.beep()
            return
        }
        agentConfiguration.persist()
        pinnedDiedAt = nil
        notNeededSince = nil
        evaluate()
        ensureHooksInstalled(force: true)
    }

    @objc func toggleGeorgeLight() {
        georgeLightConfiguration.enabled.toggle()
        georgeLightConfiguration.persistEnabled()
        lightOutput.setEnabled(georgeLightConfiguration.enabled)
    }

    @objc func setGeorgeLightAddress() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set GeorgeLight Address"
        alert.informativeText = "Enter an HTTP root address, for example http://george-light-zero.local"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = georgeLightConfiguration.baseURL.absoluteString
        input.placeholderString = GeorgeLightConfiguration.defaultBaseURL.absoluteString
        alert.accessoryView = input

        while alert.runModal() == .alertFirstButtonReturn {
            if let url = GeorgeLightConfiguration.validBaseURL(input.stringValue) {
                georgeLightConfiguration.baseURL = url
                georgeLightConfiguration.persistBaseURL()
                lightOutput.setBaseURL(url)
                return
            }
            NSSound.beep()
            alert.informativeText = "Enter a valid HTTP root address without a path, query, or fragment."
            input.selectText(nil)
        }
    }

    func georgeLightEffectMenuItem(for state: LightState) -> NSMenuItem {
        let item = NSMenuItem(title: state.settingsTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: state.settingsTitle)

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        let options = GeorgeLightColors.options(for: state)
        for (index, option) in options.enumerated() {
            if index == 1 { colorMenu.addItem(.separator()) }
            let title = "\(option.title) (\(option.hex))"
            let choice = NSMenuItem(title: title, action: #selector(chooseGeorgeLightColor(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = GeorgeLightColorSelection(state: state, color: option.hex)
            choice.state = georgeLightConfiguration.effects.effect(for: state)?.color == option.hex ? .on : .off
            colorMenu.addItem(choice)
        }
        colorItem.submenu = colorMenu
        submenu.addItem(colorItem)

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "Mode")
        for mode in GeorgeLightMode.allCases {
            let choice = NSMenuItem(title: mode.title, action: #selector(chooseGeorgeLightMode(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = GeorgeLightModeSelection(state: state, mode: mode)
            choice.state = georgeLightConfiguration.effects.effect(for: state)?.mode == mode ? .on : .off
            modeMenu.addItem(choice)
        }
        modeItem.submenu = modeMenu
        submenu.addItem(modeItem)

        item.submenu = submenu
        return item
    }

    @objc func chooseGeorgeLightColor(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? GeorgeLightColorSelection,
              var effect = georgeLightConfiguration.effects.effect(for: selection.state) else { return }
        effect.color = selection.color
        georgeLightConfiguration.effects.setEffect(effect, for: selection.state)
        georgeLightConfiguration.persistEffect(for: selection.state)
        lightOutput.setEffect(effect, for: selection.state)
    }

    @objc func chooseGeorgeLightMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? GeorgeLightModeSelection,
              var effect = georgeLightConfiguration.effects.effect(for: selection.state) else { return }
        effect.mode = selection.mode
        georgeLightConfiguration.effects.setEffect(effect, for: selection.state)
        georgeLightConfiguration.persistEffect(for: selection.state)
        lightOutput.setEffect(effect, for: selection.state)
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        loadSessions()
        evaluate()
    }

    // Reload any per-session state file whose mtime advanced. Also handles one-shot
    // backward compat: if states.d/ is empty but a legacy single state.json exists,
    // read it once under a synthetic session id so upgrades keep working until the new
    // hooks take over.
    //
    // Timeout logging lives here (not in evaluate) on purpose: selectDisplay filters
    // sessions at staleAfter=900s, so by the time evaluate sees a session its age is
    // already ≤ 900 — the age>900 safety net in evaluate would be dead code. Scanning
    // here catches sessions the moment they cross 900s while still in thinking/tool,
    // and logs each stuck episode once (deduped via timeoutLogged).
    func loadSessions() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var seen: Set<String> = []
        var seenIds: Set<String> = []
        let sources: [(AgentProvider, String)] = [(.codex, codexStatesDir), (.claude, claudeStatesDir)]
        for (provider, directory) in sources {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where !name.hasSuffix(".tmp") {
                let cacheKey = "\(provider.rawValue):\(name)"
                let p = (directory as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: p),
                      let m = attrs[.modificationDate] as? Date else { continue }
                seen.insert(cacheKey)
                if let prev = sessions[cacheKey] { seenIds.insert(prev.state.key.persistedValue) }
                if let prev = sessions[cacheKey], prev.mtime == m { continue }
                guard let data = fm.contents(atPath: p),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var st = SessionState(json: obj) else { continue }
                st.provider = provider
                let stateKey = st.key.persistedValue
                if st.normalizedState == .done || st.normalizedState == .error {
                    // A changed terminal file is a new terminal event, even when the same
                    // session previously reached Done/Error. Start a fresh short window.
                    terminalShownAt[stateKey] = Date(timeIntervalSince1970: st.ts)
                } else {
                    terminalShownAt.removeValue(forKey: stateKey)
                }
                sessions[cacheKey] = (st, m)
                seenIds.insert(stateKey)
            }
        }
        // A loaded legacy Codex state has no states.d filename to rediscover. Keep the
        // one-shot fallback cached until a real Codex state appears or the legacy file is removed.
        if !seen.contains(where: { $0.hasPrefix("codex:") }),
           fm.fileExists(atPath: legacyStatePath),
           let legacy = sessions["codex:__legacy__"] {
            seen.insert("codex:__legacy__")
            seenIds.insert(legacy.state.key.persistedValue)
        }
        for k in sessions.keys where !seen.contains(k) { sessions.removeValue(forKey: k) }
        for k in terminalShownAt.keys where !seenIds.contains(k) { terminalShownAt.removeValue(forKey: k) }
        for k in timeoutLogged where !seenIds.contains(k) { timeoutLogged.remove(k) }

        // Timeout sweep — runs EVERY tick over the in-memory cache, NOT gated by mtime.
        // A stuck session has a frozen file → frozen mtime → the loop above `continue`s
        // past it, so the age check must live here or it would never fire. Deduped via
        // timeoutLogged so each stuck episode logs once; cleared when the writer recovers
        // (new write → fresh ts → age < 900).
        for entry in sessions.values {
            let st = entry.state
            let age = now - st.ts
            let key = st.key.persistedValue
            if st.normalizedState == .working && age > 900 && !timeoutLogged.contains(key) {
                appendTimeoutLog(chosen: st, age: age)
                timeoutLogged.insert(key)
            }
            if age < 900 { timeoutLogged.remove(key) }
        }

        // One-shot legacy fallback.
        if !sessions.keys.contains(where: { $0.hasPrefix("codex:") }),
           let attrs = try? fm.attributesOfItem(atPath: legacyStatePath),
           let m = attrs[.modificationDate] as? Date, m != lastMTime {
            lastMTime = m
            if let data = fm.contents(atPath: legacyStatePath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let st = SessionState(json: obj) {
                sessions["codex:__legacy__"] = (st, m)
            }
        }
    }

    func displayEligible(_ st: SessionState, now: TimeInterval) -> Bool {
        let ownerAlive = st.ownerPid > 0 && processAlive(st.ownerPid)
        return st.isDisplayEligible(now: now, ownerAlive: ownerAlive)
    }

    func processAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        let enabled = agentConfiguration.enabledProviders
        let all = sessions.map { $0.value.state }.filter {
            enabled.contains($0.provider) && displayEligible($0, now: now)
        }
        let terminalTimes = terminalShownAt.mapValues { $0.timeIntervalSince1970 }
        let globalState = arbitrateAgentState(
            enabledProviders: enabled, sessions: all, now: now, terminalShownAt: terminalTimes)
        lightOutput.setLightState(globalState.lightState)
        guard let chosen = selectDisplay(
            pinned: pinnedSession, sessions: all, now: now, terminalShownAt: terminalTimes) else {
            render(label: "", color: iconColor, animate: false, startedAt: 0,
                   pausedTotal: 0, pauseStart: 0)
            return
        }
        let label = chosen.label
        let state = chosen.normalizedState

        // No age>900 safety net here: selectDisplay already excludes sessions older
        // than staleAfter=900s, and stuck-turn logging fires in loadSessions. By the
        // time a session reaches evaluate, it is alive and recent.

        switch state {
        case .working:
            let fallback = chosen.state == "thinking" ? "Thinking…" : "Working…"
            render(label: label.isEmpty ? fallback : label, color: iconColor, animate: true,
                   startedAt: chosen.startedAt, pausedTotal: chosen.pausedTotal, pauseStart: chosen.pauseStart)
        case .waitingApproval:
            // Timer stays visible but frozen at net time (spec §6.4). The amber dot
            // signals the pause; the clock just stops advancing until post fires.
            render(label: "Awaiting permission", color: amber, animate: false,
                   startedAt: chosen.startedAt, pausedTotal: chosen.pausedTotal,
                   pauseStart: chosen.pauseStart, dot: true)
        case .waitingInput:
            render(label: "Awaiting input", color: amber, animate: false,
                   startedAt: chosen.startedAt, pausedTotal: chosen.pausedTotal,
                   pauseStart: chosen.pauseStart, dot: true)
        case .waitingImplementation:
            render(label: "Awaiting implementation", color: amber, animate: false,
                   startedAt: 0, pausedTotal: 0, pauseStart: 0, dot: true)
        case .error:
            renderTerminal(chosen: chosen, now: now, label: "Error", color: errorRed, doneIcon: false)
        case .done:
            renderTerminal(
                chosen: chosen, now: now, label: "Done",
                color: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1), doneIcon: true)
        case .idle:
            render(label: "", color: iconColor, animate: false, startedAt: 0,
                   pausedTotal: 0, pauseStart: 0)
        }
    }

    // Show a brief Done/Error confirmation for 2s after a terminal event, then return
    // to the resting mark so terminal state files cannot hold the UI or light forever.
    // The terminalShownAt entry is a permanent "already shown" sentinel (NOT cleared
    // after 2s) — clearing it would replay Done/Error while the state file is unchanged.
    // loadSessions prunes the entry when the session file disappears.
    func renderTerminal(chosen: SessionState, now: TimeInterval, label: String,
                        color: NSColor, doneIcon: Bool) {
        let key = chosen.key.persistedValue
        let shownAt = terminalShownAt[key]?.timeIntervalSince1970 ?? chosen.ts
        terminalShownAt[key] = Date(timeIntervalSince1970: shownAt)
        if now - shownAt > SessionState.terminalVisibleFor {
            render(label: "", color: iconColor, animate: false,
                   startedAt: 0, pausedTotal: 0, pauseStart: 0)
            return
        }
        render(label: label, color: color, animate: false, startedAt: 0,
               pausedTotal: 0, pauseStart: 0, dot: !doneIcon, done: doneIcon)
    }

    func appendTimeoutLog(chosen: SessionState, age: TimeInterval) {
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            ".\(chosen.provider.rawValue)/statusbar/app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) TIMEOUT provider=\(chosen.provider.rawValue) session=\(chosen.sessionId) state=\(chosen.state) age=\(Int(age)) project=\(chosen.project)\n"
        appendPrivateLogLine(line, toPath: logPath)
    }

    // MARK: self-quit lifecycle

    // True while a Codex process is running. The CLI, `codex exec`, and the app-server
    // backing the desktop app and the VS Code extension all run as an executable named
    // `codex`, so an exact-name match catches every surface without the false positives a
    // broad command-line match invites (e.g. an MCP server with .codex in its argv).
    func providerRunning(_ provider: AgentProvider) -> Bool {
        pgrepMatches(["-x", provider == .codex ? "codex" : "claude"])
    }

    func pgrepMatches(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 && !data.isEmpty
    }

    // A session is "fresh" if any file in sessions.d/ was modified within freshWindow
    // seconds — covers the gap right after launch before a process is visible.
    func freshSession(_ provider: AgentProvider) -> Bool {
        let fm = FileManager.default
        let directory = provider == .codex ? codexSessionsDir : claudeSessionsDir
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return false }
        let now = Date()
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let m = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(m) <= freshWindow {
                return true
            }
        }
        return false
    }

    func activeOwnedSession(_ provider: AgentProvider) -> Bool {
        sessions.values.contains {
            let state = $0.state
            return state.provider == provider && state.hasReliableOwner() && processAlive(state.ownerPid)
        }
    }

    // Stay while Codex is running OR a session was just touched; otherwise quit (after a
    // short, debounced grace so warmup churn and relaunches don't kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        let needed = agentConfiguration.enabledProviders.contains {
            providerRunning($0) || activeOwnedSession($0) || freshSession($0)
        }
        if needed {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: TimeInterval,
                pausedTotal: TimeInterval = 0, pauseStart: TimeInterval = 0, dot: Bool = false, done: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        activeStartedAt = startedAt
        activePausedTotal = pausedTotal
        activePauseStart = pauseStart

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            if done { button.image = checkIcon(color: color) }
            else if dot { button.image = dotIcon(color: color) }
            else { button.image = restingIcon(color: color) }
        }
        applyTitle()
        if button.image == nil { button.image = done ? checkIcon(color: color) : (dot ? dotIcon(color: color) : restingIcon(color: color)) }
        button.setAccessibilityLabel("Codex status: \(label.isEmpty ? "idle" : label)")
    }

    // Reproduce the thinking animation: step through the frame masks.
    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, activeStartedAt > 0 {
            let secs = elapsedSeconds(now: Date().timeIntervalSince1970,
                                      startedAt: activeStartedAt,
                                      pausedTotal: activePausedTotal,
                                      pauseStart: activePauseStart)
            let m = secs / 60, s = secs % 60
            text += "  " + (m > 0 ? "\(m)m \(s)s" : "\(s)s") // e.g. "1m 1s" / "43s"
        }
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    // The prompt morph frames, rasterized into alpha masks (SparkFrames.swift).
    // Decoded once at launch.
    static func loadFrames() -> [NSImage] { decodePNGs(codexSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage { tint(frames, color: color, frame: frame) }

    // The resting icon is the Codex prompt mark.
    let logoSet: [NSImage] = Data(base64Encoded: codexLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage { tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0) }

    // A small filled dot — used for the paused "awaiting permission" state.
    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // A small checkmark — used for the 2s "Done" confirmation.
    func checkIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemGreen).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 4, y: 9))
            path.line(to: NSPoint(x: 7.5, y: 5))
            path.line(to: NSPoint(x: 14, y: 13))
            path.stroke()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha, so the same frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
