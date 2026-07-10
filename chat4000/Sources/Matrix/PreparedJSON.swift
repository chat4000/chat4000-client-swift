import Foundation

enum PreparedJSONValue: Sendable {
    case object([String: PreparedJSONValue])
    case array([PreparedJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(any value: Any) {
        switch value {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { PreparedJSONValue(any: $0) })
        case let array as [Any]:
            self = .array(array.map { PreparedJSONValue(any: $0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool:
            self = .bool(bool)
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.anyValue)
        case .array(let array):
            return array.map(\.anyValue)
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }
}

struct PreparedJSON: Sendable {
    let root: PreparedJSONValue

    var objectValue: [String: Any]? {
        guard case .object(let object) = root else { return nil }
        return object.mapValues(\.anyValue)
    }

    static func parse(_ string: String?) -> PreparedJSON? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return PreparedJSON(root: PreparedJSONValue(any: object))
    }
}
