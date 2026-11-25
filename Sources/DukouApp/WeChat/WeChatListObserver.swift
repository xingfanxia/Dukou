import AppKit
import ApplicationServices
import Combine
import DukouCore
import Foundation

/// Watches WeChat's message list while the user works in it, so that a
/// forward made by hand can be given the transcripts its TXT leaves out.
///
/// Read-only, and only while it is allowed to look: Dukou already holds
/// Accessibility (it never asks for it from here), WeChat is the frontmost
/// app, and no quick forward is driving WeChat. It posts no event, presses
/// nothing and brings nothing forward; it reads the rows WeChat has laid out
/// around the viewport, which is what is on screen. What they say is kept in
/// `WeChatListMemory`, in memory only, and dropped when WeChat quits.
///
/// A look costs one read of the chat's name, one of the list (its children
/// and frame) and one per laid-out child at the bottom of it — typically a
/// dozen or two cross-process calls. Looks come every 0.12 s while the list
/// is changing and every 0.4 s once it has been still for 3 s. Finding the
/// list and the chat's name walks WeChat's window — under a hundred reads
/// with a conversation open — and is done again every second: see `look`.
final class WeChatListObserver: @unchecked Sendable {
    static let busyInterval = 0.12
    static let idleInterval = 0.4
    static let settleSeconds = 3.0
    /// Laid-out children read per look, from the bottom; WeChat lays out
    /// about a viewport's worth.
    static let maximumChildren = 64
    /// What one look, and one search for the list, may take at most.
    static let lookBudget = 0.4
    static let searchBudget = 1.0
    private static let timeout: Float = 0.25
    private static let rowKeys = ["AXRole", "AXIdentifier", "AXTitle", "AXValue", "AXPosition", "AXSize"] as CFArray
    private static let listKeys = ["AXChildren", "AXPosition", "AXSize"] as CFArray

    private let queue = DispatchQueue(label: "dev.dukou.wechat.list", qos: .utility)
    // Everything below is `queue`'s.
    private var memory = WeChatListMemory()
    private var generation = 0
    private var pid: pid_t?
    private var watching = false
    private var root: AXUIElement?
    private var list: AXUIElement?
    private var label: AXUIElement?
    private var chat = ""
    private var lastSignature = ""
    private var lastChange = -Double.infinity
    private var lastSearch = -Double.infinity
    private var polls = 0, looks = 0, searches = 0
    private var lost = 0, unclear = 0
    private var pollSeconds = 0.0, slowestPoll = 0.0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Look at the WeChat process `pid`, or stop looking when nil. A
    /// different process is a WeChat that restarted: nothing seen before
    /// belongs to it.
    func watch(_ pid: pid_t?) {
        queue.async { [self] in
            if let pid, pid != self.pid {
                forgetEverything()
                self.pid = pid
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, Self.timeout)
                self.root = root
            }
            let start = pid != nil
            guard start != watching else { return }
            watching = start
            generation += 1
            memory.interrupt()
            lastSignature = ""
            if start {
                tick(generation)
            } else {
                // Nothing is looked at while WeChat is behind, so nothing
                // would prune; the age limit still holds.
                let generation = self.generation
                queue.asyncAfter(deadline: .now() + memory.maximumAge + 1) { [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.memory.prune(now: Date())
                }
            }
        }
    }

    /// WeChat quit.
    func forget() {
        queue.async { [self] in
            forgetEverything()
            pid = nil
            root = nil
        }
    }

    /// Before the batch at `directory` is delivered: its TXT gains whatever
    /// transcripts the rows seen of `chat` pin down, and manual-forward.json
    /// says how that went, after the `earlier` steps the batch already went
    /// through. Counts only.
    func mergeTranscripts(intoBatchAt directory: URL, chat: String, exportedAt: Date, after earlier: [[String: Any]] = []) {
        let (evidence, observer) = queue.sync { [self] () -> (WeChatListEvidence, [String: Any]) in
            memory.prune(now: Date())
            return (memory.evidence(chat: chat, exportedAt: exportedAt), diagnosis(asked: chat))
        }
        let step = WeChatArchive.mergeObservedVoiceTranscripts(evidence, directory: directory)
        WeChatArchive.recordManualForward(earlier + [step], observer: observer)
    }

    /// Why a conversation that was watched can still come back empty: sizes
    /// and counts of the two names, never the names.
    private func diagnosis(asked: String) -> [String: Any] {
        func size(_ text: String) -> [String: Int] {
            ["characters": text.count, "scalars": text.unicodeScalars.count, "bytes": text.utf8.count]
        }
        let held = memory.held(chat: asked)
        var report = report()
        report["asked"] = size(asked)
        report["watching"] = size(chat)
        report["askedIsWatching"] = WeChatForwardPreset.normalizedChat(asked) == chat
        report["stretchesOfAsked"] = held.stretches
        report["conversations"] = held.conversations
        report["results"] = ["lost": lost, "unclear": unclear]
        return report
    }

    /// TEMPORARY (diagnosing not-observed): every half minute of watching,
    /// what a forward arriving now would be told. Counts only.
    private var lastSelfCheck = -Double.infinity
    private func selfCheck() {
        guard now - lastSelfCheck >= 30 else { return }
        lastSelfCheck = now
        let asked = (try? WeChatAccessibility.currentChat()) ?? ""
        var report = diagnosis(asked: asked)
        report["at"] = ISO8601DateFormatter().string(from: Date())
        report["evidenceStretches"] = memory.evidence(chat: asked, exportedAt: Date()).stretches.count
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dukou/WeChat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("watch.json"), options: .atomic)
        }
    }

    private func report() -> [String: Any] {
        ["polls": polls, "looks": looks, "searches": searches, "stretches": memory.stretchCount, "rowsHeld": memory.rowCount,
         "averagePollMilliseconds": polls > 0 ? pollSeconds / Double(polls) * 1000 : 0, "slowestPollMilliseconds": slowestPoll * 1000]
    }

    private func forgetEverything() {
        memory.forget()
        list = nil
        label = nil
        chat = ""
        lastSignature = ""
    }

    private func tick(_ generation: Int) {
        guard generation == self.generation, watching else { return }
        poll()
        selfCheck()
        let interval = now - lastChange < Self.settleSeconds ? Self.busyInterval : Self.idleInterval
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.tick(generation) }
    }

    private func poll() {
        let started = now
        defer {
            let spent = now - started
            polls += 1
            pollSeconds += spent
            slowestPoll = max(slowestPoll, spent)
        }
        // On every poll, not only when something new is seen: a list left
        // still must not keep other chats past the age limit.
        memory.prune(now: Date())
        switch look() {
        case .lost:
            lost += 1
            memory.interrupt()
            lastSignature = ""
        case .unclear:
            unclear += 1
        case .window(let rows):
            let signature = chat + "\u{1}" + rows.map { "\($0.title)|\($0.ticked.map(String.init) ?? "-")|\($0.y)|\($0.height)" }
                .joined(separator: "\u{1}")
            guard signature != lastSignature else { return }
            lastSignature = signature
            lastChange = now
            looks += 1
            memory.observe(chat: chat, rows: rows, at: Date())
        }
    }

    private enum Look {
        /// No list to read: whatever comes next does not follow what came before.
        case lost
        /// A list mid-redraw; the next look may still follow the last.
        case unclear
        case window([WeChatListRow])
    }

    private func look() -> Look {
        guard let root else { return .lost }
        // Found afresh once a second, and no oftener: a window with no
        // conversation open would otherwise be walked on every look. Not kept
        // until they fail, because they do not fail: WeChat goes on answering
        // for a list and a name it no longer shows, and rows would be filed
        // under a conversation the user has left.
        var found = false
        if now - lastSearch >= 1 {
            lastSearch = now
            searches += 1
            locate(in: root)
            found = true
        }
        guard let list, let label, let name = Self.text(of: label) else {
            self.list = nil
            return .lost
        }
        let current = WeChatForwardPreset.normalizedChat(name)
        if current != chat {
            let first = chat.isEmpty
            chat = current
            if !first {
                // Another conversation may come with another list. One just
                // found is this conversation's; an older one is found again
                // rather than read under the new name.
                guard found else { self.list = nil; return .lost }
                memory.interrupt()
                lastSignature = ""
            }
        }
        guard !chat.isEmpty, let values = Self.values(of: list, Self.listKeys), values.count == 3,
              let children = values[0] as? [AXUIElement] else {
            self.list = nil
            return .lost
        }
        let frame = Self.rect(values[1], values[2])
        var rows: [WeChatListRow] = []
        var gap = false
        let deadline = now + Self.lookBudget
        for child in children.reversed().prefix(Self.maximumChildren) {
            // A WeChat slow to answer gives up this look, not the queue that
            // a batch's merge waits on.
            guard now < deadline else { return .unclear }
            AXUIElementSetMessagingTimeout(child, Self.timeout)
            guard let values = Self.values(of: child, Self.rowKeys), values.count == 6 else { return .unclear }
            let role = values[0] as? String ?? "", id = values[1] as? String ?? ""
            let rect = Self.rect(values[4], values[5])
            if id == "virtual_cell" {
                // The placeholders before the laid-out rows; one with a size
                // between two rows would be a row WeChat has not laid out.
                if rect.isEmpty { break }
                if !rows.isEmpty { gap = true }
                continue
            }
            guard id == "chat_bubble_item_view" else { continue }
            guard !rect.isEmpty, frame.isEmpty || (rect.maxY > frame.minY && rect.minY < frame.maxY) else {
                if !rows.isEmpty { gap = true }
                continue
            }
            if gap { return .unclear }
            let title = (values[2] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (values[3] as? String) ?? ""
            var ticked: Bool?
            if role == "AXCheckBox" {
                // A checkbox that does not say is not taken as unticked.
                guard let value = values[3] as? NSNumber else { return .unclear }
                ticked = value.boolValue
            }
            rows.append(WeChatListRow(title: title, ticked: ticked, y: rect.minY, height: rect.height))
        }
        return rows.isEmpty ? .unclear : .window(rows.reversed())
    }

    /// The message list and the chat's name label of one window: the focused
    /// one first. Walks no further into the list, the menu bar, or past a
    /// couple of thousand elements.
    private func locate(in root: AXUIElement) {
        list = nil
        label = nil
        var windows = Self.value(root, "AXWindows") as? [AXUIElement] ?? []
        if let focused = Self.value(root, "AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let window = focused as! AXUIElement
            windows.removeAll { CFEqual($0, window) }
            windows.insert(window, at: 0)
        }
        var visited = 0
        let deadline = now + Self.searchBudget
        for window in windows {
            var queue = [window], index = 0
            var foundList: AXUIElement?, foundLabel: AXUIElement?
            while index < queue.count, visited < 2000, now < deadline, foundList == nil || foundLabel == nil {
                let element = queue[index]
                index += 1; visited += 1
                AXUIElementSetMessagingTimeout(element, Self.timeout)
                guard let values = Self.values(of: element, ["AXRole", "AXIdentifier", "AXChildren"] as CFArray), values.count == 3 else { continue }
                let role = values[0] as? String ?? "", id = values[1] as? String ?? ""
                if id == "chat_message_list" { foundList = element; continue }
                if id == "current_chat_name_label" { foundLabel = element }
                if role != "AXMenuBar" { queue.append(contentsOf: values[2] as? [AXUIElement] ?? []) }
            }
            if let foundList, let foundLabel {
                list = foundList
                label = foundLabel
                return
            }
        }
    }

    // MARK: - AX

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// One cross-process call for several attributes. A missing attribute
    /// comes back as an error value, read here as nil.
    private static func values(of element: AXUIElement, _ keys: CFArray) -> [Any?]? {
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys, [], &copied) == .success,
              let values = copied as? [Any] else { return nil }
        return values.map { value in
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    private static func text(of element: AXUIElement) -> String? {
        for name in ["AXTitle", "AXValue"] {
            if let text = value(element, name) as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private static func rect(_ position: Any?, _ size: Any?) -> CGRect {
        var point = CGPoint.zero, extent = CGSize.zero
        if let position, CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(position as! AXValue, .cgPoint, &point) }
        if let size, CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
        return CGRect(origin: point, size: extent)
    }
}

/// Decides when `WeChatListObserver` may look: Accessibility granted, WeChat
/// in front, no quick forward running. Tells it when WeChat quits.
@MainActor
final class WeChatListWatch {
    private let observer: WeChatListObserver
    private let authorization: AccessibilityAuthorization
    private var automationBusy = false
    private var subscriptions = Set<AnyCancellable>()

    init(observer: WeChatListObserver, authorization: AccessibilityAuthorization, automationBusy: AnyPublisher<Bool, Never>) {
        self.observer = observer
        self.authorization = authorization
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == WeChatAccessibility.bundleIdentifier { self?.observer.forget() }
                self?.refresh()
            }
            .store(in: &subscriptions)
        authorization.$isTrusted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        automationBusy
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] busy in
                self?.automationBusy = busy
                self?.refresh()
            }
            .store(in: &subscriptions)
        refresh()
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        let allowed = authorization.isTrusted && !automationBusy && front?.bundleIdentifier == WeChatAccessibility.bundleIdentifier
        observer.watch(allowed ? front?.processIdentifier : nil)
    }
}
