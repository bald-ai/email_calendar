#if os(macOS)
import AppKit
import Observation

/// "AI add" in the overlay: type or paste a screenshot, get events back with their dates spelled out
/// and anything doubtful flagged, then add them one by one after a look.
@MainActor @Observable
final class EventAssistant {
    struct Attachment: Identifiable {
        let id = UUID()
        let image: NSImage
        let upload: EventExtractor.Image
    }

    var isOpen = false
    var text = ""
    private(set) var attachments: [Attachment] = []
    private(set) var isWorking = false
    var proposals: [ExtractedEvent] = []
    private let additions = ProposalAddState()
    var pendingAdds: Set<ExtractedEvent.ID> { additions.pending }

    func beginAdd(_ id: ExtractedEvent.ID) -> Bool { additions.begin(id) }
    func endAdd(_ id: ExtractedEvent.ID) { additions.finish(id) }
    private(set) var message: String?
    /// Bumped whenever the bar should take keyboard focus (opened, or an image arrived).
    private(set) var focusRequest = 0
    /// Calendars the AI may pick from when you name one; set by the panel.
    @ObservationIgnored var calendarNames: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Shows the AI panel; set by the overlay controller.
    @ObservationIgnored var onOpen: (() -> Void)?

    func open() {
        isOpen = true
        focusRequest += 1
        onOpen?()
    }

    func close() {
        task?.cancel(); task = nil
        isOpen = false; isWorking = false
        text = ""; attachments = []; proposals = []; message = nil
    }

    /// Returns false when the image can't be read.
    @discardableResult
    func attach(_ image: NSImage) -> Bool {
        guard let upload = Self.prepare(image) else { return false }
        attachments.append(Attachment(image: image, upload: upload))
        open()
        return true
    }

    func remove(_ id: Attachment.ID) { attachments.removeAll { $0.id == id } }

    /// Back to step one with an empty box.
    func startOver() {
        task?.cancel(); task = nil
        isWorking = false
        text = ""; attachments = []; proposals = []; message = nil
        focusRequest += 1
    }

    var canRun: Bool { !isWorking && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    // MARK: Models

    enum Provider { case anthropic, openAI }

    /// Selected after the October 29 benchmark: Terra low first, Haiku medium on failure.
    static let preferred: Provider = .openAI
    static let haiku = EventExtractorSettings(model: "claude-haiku-5-5", reasoning: "medium")
    static let terra = EventExtractorSettings(model: "gpt-6.1-terra", reasoning: "low", serviceTier: "default")

    /// Extractors to try, in order, for the providers that have a key.
    static func extractors() -> [EventExtractor] {
        let anthropic = Credential.anthropicKey.value.map {
            EventExtractor(apiKey: $0, settings: haiku, anthropicWorkspaceID: Credential.anthropicWorkspace.value)
        }
        let openAI = Credential.openAIKey.value.map { EventExtractor(apiKey: $0, settings: terra) }
        return (preferred == .anthropic ? [anthropic, openAI] : [openAI, anthropic]).compactMap { $0 }
    }

    static var modelSummary: String {
        let names = [Provider.anthropic: "Claude Haiku 5.5 · medium effort", .openAI: "GPT-6.1 Terra · low reasoning"]
        return "\(names[preferred]!) · backup: \(names[preferred == .anthropic ? .openAI : .anthropic]!)"
    }

    func run() {
        guard canRun else { return }
        let extractors = Self.extractors()
        guard !extractors.isEmpty else { message = EventExtractorError.missingKey.localizedDescription; return }
        let text = text, images = attachments.map(\.upload), calendars = calendarNames
        isWorking = true; message = nil; proposals = []
        task = Task {
            var failure: (any Error)?
            for extractor in extractors {
                do {
                    let result = try await extractor.extract(text: text, images: images, calendars: calendars)
                    guard !Task.isCancelled else { return }
                    proposals = result.events
                    message = result.events.isEmpty ? (result.message ?? "No events found.") : nil
                    failure = nil
                    break
                } catch is CancellationError {
                    return
                } catch {
                    // Try the backup provider before giving up.
                    failure = error
                }
            }
            // A cancelled run (Start over, close) often fails with a URL error rather than CancellationError;
            // it must not touch the state of a newer run.
            guard !Task.isCancelled else { return }
            if let failure { message = failure.localizedDescription }
            isWorking = false
        }
    }

    func didAdd(_ id: ExtractedEvent.ID, title: String) {
        proposals.removeAll { $0.id == id }
        message = "Added “\(title)”."
        if proposals.isEmpty { text = ""; attachments = [] }
    }

    func reportFailure(_ text: String) { message = text }

    // MARK: Keys

    /// Preferences (Keychain) first, then Config/Secrets.xcconfig (via Info.plist), then the environment.
    enum Credential: String, CaseIterable {
        case anthropicKey = "ANTHROPIC_API_KEY"
        case anthropicWorkspace = "ANTHROPIC_WORKSPACE_ID"
        case openAIKey = "OPENAI_API_KEY"

        private var keychain: KeychainStore {
            let bundle = Bundle.main.bundleIdentifier ?? "app.emailcalendar"
            return switch self {
            case .openAIKey: KeychainStore(service: "\(bundle).openai", account: "api-key")
            case .anthropicKey: KeychainStore(service: "\(bundle).anthropic", account: "api-key")
            case .anthropicWorkspace: KeychainStore(service: "\(bundle).anthropic", account: "workspace-id")
            }
        }

        private var fromBundle: String? {
            (Bundle.main.object(forInfoDictionaryKey: rawValue) as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        }

        var value: String? {
            if let data = try? keychain.read(), let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
            return fromBundle ?? ProcessInfo.processInfo.environment[rawValue].flatMap { $0.isEmpty ? nil : $0 }
        }

        var source: String {
            if let data = try? keychain.read(), !data.isEmpty { return "Saved in Keychain" }
            if fromBundle != nil { return "From Config/Secrets.xcconfig" }
            if ProcessInfo.processInfo.environment[rawValue]?.isEmpty == false { return "From the environment" }
            return "Not set"
        }

        func save(_ value: String) throws {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { try keychain.delete() } else { try keychain.write(Data(value.utf8)) }
        }
    }

    // MARK: Images

    /// Retina screenshots are huge; the model reads text fine at 2048 px on the long side.
    private static func prepare(_ image: NSImage) -> EventExtractor.Image? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longSide = CGFloat(max(cgImage.width, cgImage.height))
        let scale = min(1, 2048 / longSide)
        let width = max(1, Int(CGFloat(cgImage.width) * scale)), height = max(1, Int(CGFloat(cgImage.height) * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]), png.count < 4_000_000 {
            return EventExtractor.Image(data: png, mimeType: "image/png")
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]).map { EventExtractor.Image(data: $0, mimeType: "image/jpeg") }
    }
}
#endif
