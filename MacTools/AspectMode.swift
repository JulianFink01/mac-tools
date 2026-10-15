import Foundation

enum AspectMode: String, CaseIterable, Codable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill:
            return "Füllen"
        case .fit:
            return "Einpassen"
        }
    }
}
