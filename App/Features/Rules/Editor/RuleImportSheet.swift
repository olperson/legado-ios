import SwiftUI

/// Open the system picker or the book source preview after the input sheet closes.
@MainActor
struct RuleImportSheet<Fields: View>: ViewModifier {
    private enum Request: Equatable {
        case files
        case text(String)
    }

    let title: String
    @Binding var isPresented: Bool
    let chooseFiles: () -> Void
    let importText: (String) async -> Void
    let dismissAfterImport: Bool
    let fields: (Binding<String>) -> Fields
    @State private var value = ""
    @State private var request: Request?

    init(_ title: String, isPresented: Binding<Bool>, dismissAfterImport: Bool = false, chooseFiles: @escaping () -> Void,
         importText: @escaping (String) async -> Void, @ViewBuilder fields: @escaping (Binding<String>) -> Fields) {
        self.title = title
        _isPresented = isPresented
        self.dismissAfterImport = dismissAfterImport
        self.chooseFiles = chooseFiles
        self.importText = importText
        self.fields = fields
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: finish) {
            ReadingNavigationStack {
                VStack(alignment: .leading, spacing: 0) {
                    Button { submit(.files) } label: { Label("选择 JSON 文件", systemImage: "doc.badge.plus") }
                        .disabled(request != nil)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    fields($value)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") { submit(.text(value)) }
                            .disabled(request != nil || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .task(id: request) {
                    guard dismissAfterImport, case .text(let input) = request else { return }
                    await importText(input)
                    if !Task.isCancelled { isPresented = false }
                }
            }
        }
    }

    private func submit(_ selection: Request) {
        request = selection
        if dismissAfterImport, case .text = selection { return }
        isPresented = false
    }

    private func finish() {
        let selection = request
        request = nil
        value = ""
        switch selection {
        case .files: chooseFiles()
        case .text(let input) where !dismissAfterImport: Task { await importText(input) }
        default: break
        }
    }
}
