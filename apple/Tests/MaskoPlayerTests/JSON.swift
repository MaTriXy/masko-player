import Foundation

/// A JSON value for the tests: read with JSONSerialization, compared as the
/// scenarios mean it, written back for the engine.
enum JSON: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(_ any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSON.init))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSON.init))
        default:
            self = .null
        }
    }

    init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(file: URL) throws {
        try self.init(data: Data(contentsOf: file))
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return NSNumber(value: b)
        case let .int(i): return NSNumber(value: i)
        case let .double(d): return NSNumber(value: d)
        case let .string(s): return s
        case let .array(a): return a.map(\.foundation)
        case let .object(o): return o.mapValues(\.foundation)
        }
    }

    var text: String {
        let data = try! JSONSerialization.data(
            withJSONObject: foundation, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    var description: String { text }

    subscript(key: String) -> JSON? {
        get {
            if case let .object(o) = self { return o[key] }
            return nil
        }
        set {
            if case var .object(o) = self {
                o[key] = newValue
                self = .object(o)
            }
        }
    }

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var array: [JSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var object: [String: JSON]? {
        if case let .object(o) = self { return o }
        return nil
    }

    /// A number, with true as 1 and false as 0.
    var number: Double? {
        switch self {
        case let .bool(b): return b ? 1 : 0
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// Equality as the scenarios mean it: a boolean equals the number 1 or 0.
    func same(_ other: JSON) -> Bool {
        switch (self, other) {
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.same($1) }
        case let (.object(x), .object(y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map(v.same) ?? false }
        default:
            if let a = number, let b = other.number { return a == b }
            return self == other
        }
    }

    /// Merges an object into this one; `null` removes a field.
    mutating func merge(_ patch: JSON) {
        guard case var .object(base) = self, case let .object(changes) = patch else { return }
        for (k, v) in changes {
            if v == .null {
                base[k] = nil
            } else if case .object = v, var existing = base[k], case .object = existing {
                existing.merge(v)
                base[k] = existing
            } else {
                base[k] = v
            }
        }
        self = .object(base)
    }
}
