import CoreTransferable
import RtechWhisperKit
import SwiftUI
import UniformTypeIdentifiers

/// A note or history item handed to the share sheet as a `.md` or `.txt`
/// file, as the desktop's Export menu saves it. The system writes the file;
/// the app stores nothing.
struct ExportFile: Transferable {
    let name: String
    let text: String
    let format: ExportFormat

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType("net.daringfireball.markdown") ?? .plainText) {
            Data($0.text.utf8)
        }
        .suggestedFileName { $0.name }
        .exportingCondition { $0.format == .md }
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
            .suggestedFileName { $0.name }
            .exportingCondition { $0.format == .txt }
    }
}

/// "Share as Markdown" and "Share as text" for one title and text source.
struct ExportMenu: View {
    let title: String?
    let text: (ExportFormat) -> String

    var body: some View {
        Menu("Share", systemImage: "square.and.arrow.up") {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                let name = TextExport.fileName(title: title, format: format)
                ShareLink(
                    item: ExportFile(name: name, text: text(format), format: format),
                    preview: SharePreview(name)
                ) {
                    Label(format == .md ? "Share as Markdown" : "Share as text", systemImage: "doc.text")
                }
            }
        }
    }
}
