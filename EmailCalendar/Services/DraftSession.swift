import Foundation
import Observation

/// The app owns this session, so changing pages cannot cancel a debounce or discard the editor buffer.
@MainActor @Observable
final class DraftSession {
    var message: OutgoingMessage { didSet { scheduleSave() } }
    var to: String { didSet { scheduleSave() } }
    var cc: String { didSet { scheduleSave() } }
    var bcc: String { didSet { scheduleSave() } }
    private(set) var isSaving = false
    private(set) var isSending = false
    private(set) var savedAt: Date?
    var errorText: String?

    @ObservationIgnored private var lastSaved: OutgoingMessage?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<OutgoingMessage, Error>?
    @ObservationIgnored private var saver: (@MainActor @Sendable (OutgoingMessage) async throws -> OutgoingMessage)?
    @ObservationIgnored private var sender: (@MainActor @Sendable (OutgoingMessage) async throws -> Void)?
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var applyingSavedID = false
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private var wasSent = false

    init(message: OutgoingMessage, delay: Duration = .seconds(2)) {
        self.message = message
        to = message.to.joined(separator: ", ")
        cc = message.cc.joined(separator: ", ")
        bcc = message.bcc.joined(separator: ", ")
        self.delay = delay
        if message.draftID != nil { lastSaved = message }
    }

    var outgoing: OutgoingMessage {
        var value = message
        value.to = Self.addresses(to); value.cc = Self.addresses(cc); value.bcc = Self.addresses(bcc)
        return value
    }

    func configure(save: @escaping @MainActor @Sendable (OutgoingMessage) async throws -> OutgoingMessage,
                   send: @escaping @MainActor @Sendable (OutgoingMessage) async throws -> Void) {
        saver = save; sender = send
        scheduleSave()
    }

    private func scheduleSave() {
        guard !applyingSavedID, !isSending, !wasSent, !isCancelled, saver != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.debounce = nil
            do { try await self.flush() } catch { self.errorText = "Draft could not be saved: \(error.localizedDescription)" }
        }
    }

    /// Wait for an in-flight save, then save any changes typed while that request was running.
    func flush() async throws {
        debounce?.cancel(); debounce = nil
        guard !isCancelled else { throw CancellationError() }
        guard let saver else { return }
        while outgoing != lastSaved {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            guard !isSending, !wasSent else { return }
            if let saving { _ = try await saving.value; continue }
            let snapshot = outgoing
            if snapshot.draftID == nil && snapshot.to.isEmpty && snapshot.cc.isEmpty && snapshot.bcc.isEmpty && snapshot.subject.isEmpty && snapshot.body.isEmpty && snapshot.attachments.isEmpty {
                lastSaved = snapshot; return
            }
            isSaving = true; errorText = nil
            // Publish the saved ID inside the task, before any other waiter resumes.
            let task = Task {
                defer { saving = nil; isSaving = false }
                let saved = try await saver(snapshot)
                applyingSavedID = true
                message.draftID = saved.draftID
                applyingSavedID = false
                var accepted = snapshot; accepted.draftID = saved.draftID
                lastSaved = accepted; savedAt = .now
                return saved
            }
            saving = task
            _ = try await task.value
        }
    }

    func send() async throws {
        guard !isCancelled else { throw CancellationError() }
        guard !isSending, !wasSent, let sender else { return }
        isSending = true
        debounce?.cancel(); debounce = nil
        defer { isSending = false; if !wasSent { scheduleSave() } }
        if let saving { _ = try await saving.value }
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        try await sender(outgoing)
        wasSent = true
    }

    func cancel() { isCancelled = true; debounce?.cancel(); debounce = nil; saving?.cancel() }

    /// Used only when an attempted app restart failed and the retained editor becomes active again.
    func resume() { isCancelled = false; scheduleSave() }

    static func addresses(_ value: String) -> [String] {
        MailMapping.mailboxes(value, allowsSemicolons: true)
    }
}
