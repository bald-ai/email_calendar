import Foundation
import Observation

/// The app owns this session, so changing pages cannot cancel a debounce or discard the editor buffer.
@MainActor @Observable
final class DraftSession {
    struct Buffer: Codable, Sendable, Equatable {
        var message: OutgoingMessage
        var to: String
        var cc: String
        var bcc: String
        var sendNeedsVerification: Bool? = nil
    }

    var message: OutgoingMessage { didSet { scheduleSave() } }
    var to: String { didSet { scheduleSave() } }
    var cc: String { didSet { scheduleSave() } }
    var bcc: String { didSet { scheduleSave() } }
    private(set) var isSaving = false
    private(set) var isSending = false
    private(set) var savedAt: Date?
    var errorText: String?
    private(set) var sendNeedsVerification = false

    @ObservationIgnored private var lastSaved: OutgoingMessage?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<OutgoingMessage, Error>?
    @ObservationIgnored private var sending: Task<Void, Error>?
    @ObservationIgnored private var saver: (@MainActor @Sendable (OutgoingMessage) async throws -> OutgoingMessage)?
    @ObservationIgnored private var sender: (@MainActor @Sendable (OutgoingMessage) async throws -> Void)?
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var applyingSavedID = false
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private var wasSent = false

    init(message: OutgoingMessage, delay: Duration = .seconds(2)) {
        var message = message
        if message.rfcMessageID == nil { message.rfcMessageID = "<\(UUID().uuidString.lowercased())@emailcalendar.local>" }
        self.message = message
        to = message.to.joined(separator: ", ")
        cc = message.cc.joined(separator: ", ")
        bcc = message.bcc.joined(separator: ", ")
        self.delay = delay
        if message.draftID != nil { lastSaved = message }
    }

    init(recovering buffer: Buffer, delay: Duration = .seconds(2)) {
        var message = buffer.message
        if message.rfcMessageID == nil { message.rfcMessageID = "<\(UUID().uuidString.lowercased())@emailcalendar.local>" }
        self.message = message
        to = buffer.to; cc = buffer.cc; bcc = buffer.bcc
        self.delay = delay
        sendNeedsVerification = buffer.sendNeedsVerification ?? false
        // The recovered edits may be newer than Gmail even when they already have a draft ID.
    }

    var recoveryBuffer: Buffer? {
        guard !wasSent else { return nil }
        guard message.draftID != nil || !to.isEmpty || !cc.isEmpty || !bcc.isEmpty ||
              !message.subject.isEmpty || !message.body.isEmpty || !message.attachments.isEmpty else { return nil }
        return Buffer(message: message, to: to, cc: cc, bcc: bcc, sendNeedsVerification: sendNeedsVerification ? true : nil)
    }

    var outgoing: OutgoingMessage {
        var value = message
        value.to = Self.addresses(to); value.cc = Self.addresses(cc); value.bcc = Self.addresses(bcc)
        return value
    }

    var canSend: Bool { MIMEComposer.hasValidRecipients(outgoing) }

    func configure(save: @escaping @MainActor @Sendable (OutgoingMessage) async throws -> OutgoingMessage,
                   send: @escaping @MainActor @Sendable (OutgoingMessage) async throws -> Void) {
        saver = save; sender = send
        scheduleSave()
    }

    private func scheduleSave() {
        guard !applyingSavedID, !isSending, !sendNeedsVerification, !wasSent, !isCancelled, saver != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.debounce = nil
            do { try await self.flush() }
            catch {
                if error is MailDeliveryUncertainError { self.sendNeedsVerification = true }
                self.errorText = "Draft could not be saved: \(error.localizedDescription)"
            }
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
        let task = Task {
            defer { sending = nil; isSending = false; if !wasSent { scheduleSave() } }
            if let saving { _ = try await saving.value }
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            do { try await sender(outgoing) }
            catch {
                if error is MailDeliveryUncertainError { sendNeedsVerification = true }
                throw error
            }
            sendNeedsVerification = false
            wasSent = true
        }
        sending = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Quit waits for a send already in progress and bypasses the autosave debounce.
    func finishPendingWork() async throws {
        if let sending { try await sending.value }
        guard wasSent || saver != nil || recoveryBuffer == nil else { throw SessionError.notConfigured }
        try await flush()
    }

    private enum SessionError: LocalizedError {
        case notConfigured
        var errorDescription: String? { "The draft is not ready to save to Gmail." }
    }

    func cancel() { isCancelled = true; debounce?.cancel(); debounce = nil; saving?.cancel(); sending?.cancel() }

    /// Used only when an attempted app restart failed and the retained editor becomes active again.
    func resume() { isCancelled = false; scheduleSave() }

    static func addresses(_ value: String) -> [String] {
        MailMapping.mailboxes(value, allowsSemicolons: true)
    }
}
