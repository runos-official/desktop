import Foundation

/*
 The menu, as data.

 THE MENU IS A FUNCTION OF THE STATE, and that function is here and not in a SwiftUI view, so a test
 can run every combination of state through it and assert what must always be true:

 - no piece of text appears twice at the top level (FCR 1726: "Finishing sign in…" was both a status
   line and the Sign In button's label);
 - Sign In is offered exactly when a sign-in is required;
 - Restart VPN is offered on build drift and when the VPN status cannot be read (FCR 1730);
 - nothing that starts an action is enabled while one is running;
 - every disabled item has its reason somewhere in view.

 `MenuContentView` only draws this. It decides nothing.
*/

/// What choosing an item does. The view maps each one to a call on the coordinator.
enum MenuAction: Equatable, Sendable {
    case signIn, renewSession, connect, disconnect, signOut
    case installVPNService, restartVPN, updateRunOS
    case toggleCluster(cid: String, connected: Bool, label: String)
    case switchAccount(aid: String)
    case cancelOperation
    case showDetails
    case setLaunchAtLogin(Bool), setConnectAutomatically(Bool)
    case showConnectionStatus, showAbout, quit

    /// Whether choosing it starts something that talks to the CLI or the OS, and so must never run
    /// beside another. Cancel, details, the window openers and the two local toggles do not.
    var startsAnAction: Bool {
        switch self {
        case .signIn, .renewSession, .connect, .disconnect, .signOut, .installVPNService, .restartVPN,
             .updateRunOS, .toggleCluster, .switchAccount:
            return true
        case .cancelOperation, .showDetails, .setLaunchAtLogin, .setConnectAutomatically,
             .showConnectionStatus, .showAbout, .quit:
            return false
        }
    }
}

/// Why an item is disabled. Each case names where the person can SEE the reason.
enum DisabledReason: Equatable, Sendable {
    /// An operation is running; its text is a status line or the label of the button that started it.
    case operationRunning
    /// Signing in is the way forward; the Sign In button is in view.
    case signInRequired
    /// The service is not installed; the Install item is in view.
    case serviceMissing
    /// The status could not be read; an error or "Cannot read" line is in view.
    case statusUnavailable
    /// The item's own title says it ("RunOS Is Up to Date", "Checking for Updates…", a checkmark).
    case saysItself
    /// There is no tunnel; the VPN submenu holds Connect, or the sign-in or install remedy is in view.
    case noTunnel
}

struct MenuItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case button
        case toggle
        case submenu([MenuItem])
        case divider
    }

    let id: String
    let kind: Kind
    let title: String
    var action: MenuAction?
    var isOn = false
    var enabled = true
    var disabledReason: DisabledReason?

    static func text(_ id: String, _ text: String) -> MenuItem {
        MenuItem(id: id, kind: .text, title: text)
    }

    static func divider(_ id: String) -> MenuItem {
        MenuItem(id: id, kind: .divider, title: "")
    }

    static func button(
        _ id: String, _ title: String, _ action: MenuAction,
        enabled: Bool = true, reason: DisabledReason? = nil
    ) -> MenuItem {
        MenuItem(id: id, kind: .button, title: title, action: action, enabled: enabled,
                 disabledReason: enabled ? nil : reason)
    }

    static func toggle(
        _ id: String, _ title: String, isOn: Bool, _ action: MenuAction,
        enabled: Bool = true, reason: DisabledReason? = nil
    ) -> MenuItem {
        MenuItem(id: id, kind: .toggle, title: title, action: action, isOn: isOn, enabled: enabled,
                 disabledReason: enabled ? nil : reason)
    }

    static func submenu(
        _ id: String, _ title: String, _ items: [MenuItem],
        enabled: Bool = true, reason: DisabledReason? = nil
    ) -> MenuItem {
        MenuItem(id: id, kind: .submenu(items), title: title, enabled: enabled,
                 disabledReason: enabled ? nil : reason)
    }

    /// The words this item puts in front of a person. Dividers have none.
    var shownText: String? {
        switch kind {
        case .divider: return nil
        default: return title
        }
    }
}

struct MenuLayout: Equatable, Sendable {
    var items: [MenuItem]
    /// The whole of every text the menu had to shorten, for the Show Details window. nil when the
    /// menu shortened nothing, in which case there is no Show Details item.
    var details: String?

    /// Every item, submenu contents included, in reading order.
    var allItems: [MenuItem] {
        func flatten(_ list: [MenuItem]) -> [MenuItem] {
            list.flatMap { item -> [MenuItem] in
                if case .submenu(let children) = item.kind { return [item] + flatten(children) }
                return [item]
            }
        }
        return flatten(items)
    }

    func item(_ id: String) -> MenuItem? { allItems.first { $0.id == id } }
}

@MainActor
enum MenuModel {
    static let serviceMissingText = "The RunOS VPN service is not installed, so the VPN cannot connect."
    static let dnsPendingText = "Connected. Cluster names are still being applied by macOS"
    static let signedOutVPNText = "Sign in to use the VPN"
    static let restartHintText = "The VPN service is on a different version than RunOS. Use Restart VPN."
    static let readingStatusText = "Reading RunOS status…"
    static let readingVPNText = "Reading VPN status…"
    static let noClustersText = "No VPN clusters available"
    static let detailsTitle = "Show Details…"

    /// What the Update RunOS item reads. Disabled for a reason that is in its own words.
    static func updateTitle(_ store: StateStore) -> (title: String, reason: DisabledReason?) {
        if store.isUpdating { return (store.updateActionTitle, .operationRunning) }
        guard !store.isBusy else { return (store.updateActionTitle, .operationRunning) }
        switch store.updateVerdictKnown {
        case .none: return ("Checking for Updates…", .saysItself)
        case .some(true) where !store.updateAvailable: return ("RunOS Is Up to Date", .saysItself)
        default: return (store.updateActionTitle, nil)
        }
    }

    /*
     @param dedupe  True in the app. False in tests that want to prove no state produces a
                    duplicate by construction, rather than have the safety net hide one.
    */
    static func build(
        store: StateStore,
        launchAtLogin: Bool,
        connectAutomatically: Bool,
        loginItemError: String?,
        now: Date,
        dedupe: Bool = true
    ) -> MenuLayout {
        var details: [String] = []
        /// A menu line for a CLI sentence, shortened when long. The whole text goes to the details.
        func line(_ id: String, _ full: String) -> MenuItem {
            let shown = ErrorPresentation.menuLine(full)
            if shown.isSummary { details.append(ErrorPresentation.fullText(full)) }
            return .text(id, shown.text)
        }

        let busy = store.isBusy
        let signInShown = store.signInRequired
        let expiry = MenuPresentation.sessionExpiry(store.vpnStatus?.session, now: now)
        // Renewing makes no sense signed out (signing in mints the new session), and showing both
        // buttons would say the operation twice.
        let renewShown = store.sessionEndingSoon(now: now) && expiry != nil && !signInShown
        let updateShown = store.isUpdating
        // ONE item carries a running operation's words: the Update item while updating, else the
        // Sign In button, else Renew, else a status line. Two carrying it is the FCR 1726 defect.
        let signInLabel = updateShown ? "Sign In" : (store.operationMessage ?? "Sign In")
        let renewLabel = updateShown ? "Renew Session" : (store.operationMessage ?? "Renew Session")

        var top: [MenuItem] = []

        if let operation = store.operationMessage,
           MenuPresentation.showsOperationLine(
               operationMessage: operation, signInButtonShown: signInShown, renewButtonShown: renewShown,
               updateButtonShown: updateShown) {
            top.append(.text("status.operation", operation))
        }
        if let notice = store.noticeMessage, !notice.isEmpty {
            top.append(line("status.notice", notice))
        }
        if store.vpnServiceMissing {
            top.append(.text("status.service-missing", serviceMissingText))
            top.append(.button("install", "Install VPN Service…", .installVPNService,
                               enabled: !busy, reason: .operationRunning))
        }
        if signInShown {
            top.append(.button("signin", signInLabel, .signIn,
                               enabled: !busy, reason: .operationRunning))
        }
        if renewShown, let expiry {
            top.append(.text("status.expiry", expiry))
            top.append(.button("renew", renewLabel, .renewSession,
                               enabled: !busy, reason: .operationRunning))
        }
        if store.dnsPending {
            top.append(.text("status.dns-pending", dnsPendingText))
        } else if let failure = store.dnsFailure {
            top.append(line("status.dns-failure", failure))
        }
        if case .unreadable(let failure) = store.vpnStatusProblem {
            top.append(.text("status.vpn-problem", failure.headline))
            top.append(line("status.vpn-problem-reason", failure.reason))
        }
        if store.vpnRestartRequired {
            top.append(.text("status.restart-hint", restartHintText))
        }
        if let error = store.errorMessage, !error.isEmpty {
            top.append(line("status.error", error))
        }
        let nothingReadYet = store.cliStatus == nil && store.errorMessage == nil
        if nothingReadYet && !busy {
            top.append(.text("status.reading", readingStatusText))
        } else if store.cliStatus != nil, store.vpnStatus == nil, store.vpnStatusProblem == nil,
                  store.errorMessage == nil, !store.vpnServiceMissing, !signInShown, !busy {
            top.append(.text("status.reading-vpn", readingVPNText))
        }
        // Show Details sits under the lines it expands. It is placed once every line is built,
        // because the login item error further down can shorten a text as well.
        let detailsSlot = top.count

        top.append(vpnSubmenu(store: store, busy: busy, expiry: expiry, now: now))
        top.append(.divider("divider.vpn"))
        top.append(contentsOf: actionItems(
            store: store, busy: busy, launchAtLogin: launchAtLogin,
            connectAutomatically: connectAutomatically, loginItemError: loginItemError, details: &details))

        if !details.isEmpty {
            top.insert(.button("details", detailsTitle, .showDetails), at: detailsSlot)
        }

        top.append(.divider("divider.window"))
        let tunnelRunning = store.vpnStatus?.running == true
        top.append(.button("connection-status", "Connection Status", .showConnectionStatus,
                           enabled: tunnelRunning, reason: .noTunnel))
        top.append(.button("about", "About RunOS Desktop", .showAbout))
        top.append(.button("quit", "Quit RunOS Desktop", .quit))

        if dedupe { top = droppingRepeatedText(top) }
        let joined = details.isEmpty ? nil : details.joined(separator: "\n\n")
        return MenuLayout(items: top, details: joined)
    }

    private static func vpnSubmenu(store: StateStore, busy: Bool, expiry: String?, now: Date) -> MenuItem {
        var children: [MenuItem] = []
        switch store.vpnMenuMode {
        case .signedOut:
            children.append(.text("vpn.signed-out", signedOutVPNText))
        case .connected:
            if let vpn = store.vpnStatus, !vpn.connectableClusters.isEmpty {
                for cluster in vpn.connectableClusters {
                    let label = MenuPresentation.clusterLabel(cluster)
                    children.append(.toggle(
                        "vpn.cluster.\(cluster.cid)", label, isOn: cluster.connected,
                        .toggleCluster(cid: cluster.cid, connected: cluster.connected, label: label),
                        enabled: !busy, reason: .operationRunning))
                }
            } else {
                children.append(.text("vpn.no-clusters", noClustersText))
            }
            children.append(.divider("vpn.divider"))
            if let expiry { children.append(.text("vpn.expiry", expiry)) }
            children.append(.button("vpn.renew", "Renew Session", .renewSession, enabled: !busy, reason: .operationRunning))
            children.append(.button("vpn.disconnect", "Disconnect", .disconnect, enabled: !busy, reason: .operationRunning))
        case .disconnected:
            children.append(.button("vpn.connect", "Connect", .connect, enabled: !busy, reason: .operationRunning))
        }
        let usable = store.vpnControlsUsable
        let reason: DisabledReason? = {
            if busy { return .operationRunning }
            if store.vpnServiceMissing { return .serviceMissing }
            if store.signInRequired { return .signInRequired }
            return store.cliStatus == nil ? .statusUnavailable : nil
        }()
        return .submenu("vpn", "VPN", children, enabled: usable && !busy, reason: reason ?? .statusUnavailable)
    }

    private static func actionItems(
        store: StateStore, busy: Bool, launchAtLogin: Bool, connectAutomatically: Bool,
        loginItemError: String?, details: inout [String]
    ) -> [MenuItem] {
        var items: [MenuItem] = []
        let update = updateTitle(store)
        items.append(.button("update", update.title, .updateRunOS,
                             enabled: store.updateActionEnabled, reason: update.reason ?? .saysItself))
        /*
         ALWAYS HERE. It used to appear only when the service build differed from the CLI's, so a
         person whose service looked current but was stuck had nothing to press (FCR 1730). Whether
         a restart is NEEDED is information, not a condition for offering it: see the hint line in
         the status block. It asks for the administrator password through VPNService.restart.
        */
        items.append(.button("restart-vpn", MenuPresentation.vpnRestartTitle, .restartVPN,
                             enabled: !busy, reason: .operationRunning))
        items.append(.toggle("launch-at-login", "Launch at Login", isOn: launchAtLogin,
                             .setLaunchAtLogin(!launchAtLogin), enabled: !busy, reason: .operationRunning))
        items.append(.toggle("connect-automatically", AutoConnect.menuLabel, isOn: connectAutomatically,
                             .setConnectAutomatically(!connectAutomatically), enabled: !busy, reason: .operationRunning))
        if let error = loginItemError, !error.isEmpty {
            let shown = ErrorPresentation.menuLine(error)
            if shown.isSummary { details.append(ErrorPresentation.fullText(error)) }
            items.append(.text("status.login-item-error", shown.text))
        }
        if store.canSwitchAccount {
            items.append(.divider("divider.accounts"))
            let children = store.accounts.map { account -> MenuItem in
                let active = store.isActiveAccount(account)
                var item = MenuItem.button("account.\(account.aid)", account.label,
                                           .switchAccount(aid: account.aid),
                                           enabled: !active && !busy,
                                           reason: active ? .saysItself : .operationRunning)
                item.isOn = active
                return item
            }
            items.append(.submenu("accounts", "Switch Account", children, enabled: !busy, reason: .operationRunning))
        }
        if store.signedIn {
            items.append(.divider("divider.signout"))
            items.append(.button("signout", "Sign Out", .signOut, enabled: !busy, reason: .operationRunning))
        }
        if busy, store.canCancelOperation, let label = store.cancelOperationLabel {
            items.append(.divider("divider.cancel"))
            items.append(.button("cancel-operation", label, .cancelOperation))
        }
        return items
    }

    /// The safety net: a text that repeats an earlier top-level text is dropped. Logic should never
    /// need it, and the matrix test runs with it off to prove that.
    private static func droppingRepeatedText(_ items: [MenuItem]) -> [MenuItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard item.kind == .text else { return true }
            return seen.insert(item.title).inserted
        }
    }
}
