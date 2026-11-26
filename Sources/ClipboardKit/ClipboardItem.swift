import Foundation
import OneMacUI

/// What a copy is, for the type filter and for how it is shown and pasted.
enum ClipboardKind: String, Codable, CaseIterable, Identifiable {
    case text, image, file, link, email

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return tr("Text", "Văn bản")
        case .image: return tr("Image", "Ảnh")
        case .file: return tr("File", "Tệp")
        case .link: return tr("Link", "Liên kết")
        case .email: return "Email"
        }
    }

    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .email: return "at"
        }
    }

    /// A single web address or e-mail address is a link or an e-mail; anything else is text.
    static func classify(_ text: String) -> ClipboardKind {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_000, !value.contains(where: \.isWhitespace) else { return .text }
        if value.range(of: #"^[^@\s/:]+@[^@\s/]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return .email }
        if value.range(of: #"^(https?|ftp)://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .link }
        // A bare domain such as "example.com/path".
        if value.range(of: #"^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil { return .link }
        return .text
    }
}

/// One copy. Text, links and e-mails keep their string; files keep their paths, one per line;
/// an image keeps the name of its PNG in the images folder.
struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: ClipboardKind
    var text: String
    var copiedAt: Date
    var isPinned: Bool
    /// Name of the app that was in front when it was copied.
    var sourceApp: String?
    /// Its bundle identifier, for showing the app's icon.
    var sourceBundleID: String?
    var imageFile: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?
    /// SHA-256 of the image, so copying the same picture twice is recognised.
    var contentHash: String?

    init(id: UUID = UUID(), kind: ClipboardKind, text: String, copiedAt: Date = Date(), isPinned: Bool = false,
         sourceApp: String? = nil, sourceBundleID: String? = nil, imageFile: String? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
         byteCount: Int? = nil, contentHash: String? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.copiedAt = copiedAt; self.isPinned = isPinned
        self.sourceApp = sourceApp; self.sourceBundleID = sourceBundleID
        self.imageFile = imageFile; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.byteCount = byteCount; self.contentHash = contentHash
    }

    /// Histories written before kinds existed hold text only and have no `kind`.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        kind = try values.decodeIfPresent(ClipboardKind.self, forKey: .kind) ?? ClipboardKind.classify(text)
        copiedAt = try values.decode(Date.self, forKey: .copiedAt)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        sourceApp = try values.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try values.decodeIfPresent(String.self, forKey: .sourceBundleID)
        imageFile = try values.decodeIfPresent(String.self, forKey: .imageFile)
        pixelWidth = try values.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try values.decodeIfPresent(Int.self, forKey: .pixelHeight)
        byteCount = try values.decodeIfPresent(Int.self, forKey: .byteCount)
        contentHash = try values.decodeIfPresent(String.self, forKey: .contentHash)
    }

    /// Two copies with the same signature are the same thing copied again.
    var signature: String {
        switch kind {
        case .image: return "image:\(contentHash ?? id.uuidString)"
        case .file: return "file:\(text)"
        case .text, .link, .email: return text
        }
    }

    var filePaths: [String] { kind == .file ? text.split(separator: "\n").map(String.init) : [] }

    /// One line for the list, and what the search looks at besides the text itself.
    var title: String {
        switch kind {
        case .image:
            guard let pixelWidth, let pixelHeight else { return ClipboardKind.image.title }
            return "\(ClipboardKind.image.title) (\(pixelWidth)×\(pixelHeight))"
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            guard let first = names.first else { return ClipboardKind.file.title }
            return names.count > 1 ? "\(first) +\(names.count - 1)" : first
        case .text, .link, .email:
            // Runs of whitespace collapsed, so indented code and multi-line text still show content.
            return text.prefix(200).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
