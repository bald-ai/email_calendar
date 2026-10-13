import Foundation

/// Exact addresses take precedence over domain decisions, with constant-time lookup.
struct SenderRuleIndex: Sendable {
    private var byKey: [String: SenderRule]

    init(_ rules: [SenderRule] = []) {
        byKey = Dictionary(rules.map { ($0.key.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func rule(for sender: String) -> SenderRule? {
        let address = sender.lowercased()
        if let exact = byKey[address] { return exact }
        guard let at = address.lastIndex(of: "@") else { return nil }
        return byKey[String(address[at...])]
    }

    mutating func insert(_ rule: SenderRule) { byKey[rule.key.lowercased()] = rule }
}
