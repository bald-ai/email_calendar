#if os(macOS)
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Lets the composer's buttons reach the editor, to insert chosen image files at the cursor.
@MainActor
final class RichTextController {
    fileprivate weak var textView: ComposerTextView?
    func insertImages(from urls: [URL]) { textView?.insertImageFiles(urls) }
    func focus() { textView.map { $0.window?.makeFirstResponder($0) } }
}

/// The composer's message editor: text plus images that sit between paragraphs. Nothing else, so
/// pasted web content arrives as plain text, while pasted or dropped images keep their full resolution.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var images: [OutgoingAttachment]
    var controller: RichTextController
    var initialFocus = false
    /// Dropped files that are not images become ordinary attachments.
    var onFiles: ([URL]) -> Void = { _ in }

    static let minimumHeight: CGFloat = 320

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerTextView {
        let view = ComposerTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.typingAttributes = ComposerTextView.attributes
        view.insertionPointColor = NSColor(Theme.text)
        view.onFiles = onFiles
        view.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        view.load(text: text, images: images)
        context.coordinator.lastText = text; context.coordinator.lastImageIDs = images.map(\.id)
        controller.textView = view
        if initialFocus { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return view
    }

    func updateNSView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.onFiles = onFiles
        controller.textView = view
        // Replace the content only when it changed from outside the editor (a reopened or recovered draft).
        if context.coordinator.lastText != text || context.coordinator.lastImageIDs != images.map(\.id) {
            view.load(text: text, images: images)
            context.coordinator.lastText = text; context.coordinator.lastImageIDs = images.map(\.id)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 640
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            view.fitImages(to: width)
        }
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(Self.minimumHeight, ceil(layout.usedRect(for: container).height) + 24))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastText = ""
        var lastImageIDs: [String] = []
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            let (text, images) = view.content()
            lastText = text; lastImageIDs = images.map(\.id)
            if parent.text != text { parent.text = text }
            if parent.images != images { parent.images = images }
            view.invalidateIntrinsicContentSize()
        }
    }
}

/// An image in the message, holding the exact bytes that will be sent. It is shown scaled to fit.
final class InlineImageAttachment: NSTextAttachment {
    let source: OutgoingAttachment

    init(source: OutgoingAttachment, maxWidth: CGFloat) {
        self.source = source
        super.init(data: nil, ofType: nil)
        image = NSImage(data: source.data)
        fit(to: maxWidth)
    }

    required init?(coder: NSCoder) { nil }

    func fit(to maxWidth: CGFloat) {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return }
        let scale = min(1, max(40, maxWidth) / size.width)
        bounds = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

final class ComposerTextView: NSTextView {
    static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph]
    }()

    var onFiles: ([URL]) -> Void = { _ in }
    private var pastedCount = 0

    private var availableWidth: CGFloat { max(200, textContainer?.containerSize.width ?? 640) }

    // MARK: Model ⇄ text

    func load(text: String, images: [OutgoingAttachment]) {
        let result = NSMutableAttributedString()
        var index = 0, run = ""
        func flush() { if !run.isEmpty { result.append(NSAttributedString(string: run, attributes: Self.attributes)); run = "" } }
        for character in text {
            guard character == RichBody.imageMarker else { run.append(character); continue }
            flush()
            if index < images.count { result.append(attachmentString(images[index])) }
            index += 1
        }
        flush()
        textStorage?.setAttributedString(result)
        undoManager?.removeAllActions()
    }

    /// The text with an image marker per image, and the images in order.
    func content() -> (String, [OutgoingAttachment]) {
        guard let storage = textStorage else { return ("", []) }
        var text = "", images: [OutgoingAttachment] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let piece = string.substring(with: range)
            if let attachment = value as? InlineImageAttachment {
                for _ in 0..<piece.count {
                    var image = attachment.source
                    image.displayWidth = Int(attachment.bounds.width)
                    text.append(RichBody.imageMarker); images.append(image)
                }
            } else {
                // Attachments of any other kind are not part of the email.
                text += piece.replacingOccurrences(of: String(RichBody.imageMarker), with: "")
            }
        }
        return (text, images)
    }

    func fitImages(to width: CGFloat) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            (value as? InlineImageAttachment)?.fit(to: width)
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    private func attachmentString(_ image: OutgoingAttachment) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: InlineImageAttachment(source: image, maxWidth: availableWidth))
        string.addAttributes(Self.attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL, .png, .tiff, .string] }

    override func paste(_ sender: Any?) {
        if !insertImages(from: .general) { pasteAsPlainText(sender) }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if insertImages(from: pboard) { return true }
        if let string = pboard.string(forType: .string) { insert(NSAttributedString(string: string, attributes: Self.attributes)); return true }
        return false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            setSelectedRange(NSRange(location: index, length: 0))
            let images = urls.filter { Self.isImage($0) }
            insertImageFiles(images)
            let others = urls.filter { !Self.isImage($0) }
            if !others.isEmpty { onFiles(others) }
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Image data on a pasteboard (a screenshot, a copied image, image files) goes in at the cursor.
    private func insertImages(from board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(Self.isImage) {
            insertImageFiles(urls); return true
        }
        // Cells from Excel or Numbers come with a picture of themselves next to the text: the text wins
        // unless the image is what was copied first (a screenshot, Copy Image).
        if board.string(forType: .string) != nil, let first = board.types?.first, first != .png, first != .tiff { return false }
        let data = board.data(forType: .png) ?? board.data(forType: .tiff)
        guard let data, let image = Self.emailImage(data, name: nextPastedName()) else { return false }
        insert(attachmentString(image))
        return true
    }

    func insertImageFiles(_ urls: [URL]) {
        var undecodable: [URL] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let image = Self.emailImage(data, name: url.lastPathComponent) else {
                undecodable.append(url); continue
            }
            insert(attachmentString(image))
        }
        // Images that can't be shown inline (SVG, PSD…) still go along, as attachments.
        if !undecodable.isEmpty { onFiles(undecodable) }
    }

    /// Goes through the normal text-change path, so ⌘Z removes it and the composer sees the change.
    private func insert(_ string: NSAttributedString) {
        insertText(string, replacementRange: selectedRange())
        typingAttributes = Self.attributes
    }

    private func nextPastedName() -> String {
        pastedCount += 1
        return pastedCount == 1 ? "Pasted image.png" : "Pasted image \(pastedCount).png"
    }

    private static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    /// PNG, JPEG and GIF go as they are. Anything else (TIFF, HEIC…) becomes a lossless PNG, which every mail app shows.
    static func emailImage(_ data: Data, name: String) -> OutgoingAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let uti = UTType(type) else { return nil }
        let id = "\(UUID().uuidString.lowercased())@emailcalendar.local"
        let base = (name as NSString).deletingPathExtension
        for (kind, mime) in [(UTType.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif")] where uti.conforms(to: kind) {
            return OutgoingAttachment(name: name, mimeType: mime, data: data, contentID: id)
        }
        guard let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return OutgoingAttachment(name: base + ".png", mimeType: "image/png", data: png, contentID: id)
    }
}
#endif
