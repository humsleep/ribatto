import SwiftUI

/// The licence texts of everything bundled with the app.
///
/// The SIL Open Font License requires the licence to travel with the fonts, and
/// the MIT licence asks the same of Pow's notice, so this screen is a shipping
/// obligation, not a courtesy — the .txt files are
/// bundled verbatim as they came from the foundries and read at runtime rather
/// than pasted into source, so they cannot drift from the files they cover.
struct LicensesView: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id: String        // resource name
        let title: String
    }
    private let items = [
        Item(id: "Anton-OFL", title: "Anton"),
        Item(id: "BebasNeue-OFL", title: "Bebas Neue"),
        Item(id: "Pow-MIT", title: "Pow"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .font(.headline)
                            Text(text(for: item.id))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("licenses", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L.s("done", lang))
                        .tint(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func text(for resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let body = try? String(contentsOf: url, encoding: .utf8) else {
            return "—"
        }
        return body
    }
}
