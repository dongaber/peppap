import Foundation

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func oneLine(limit: Int) -> String {
        let flat = split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
