import Foundation

struct ControlCommand: Decodable {
    enum Action: String, Decodable { case start, stop, mode, idle, menubar }
    let action: Action
    var value: String?
    var minutes: Int?
}

struct ControlStatus: Encodable {
    let state: String
    let acceptingRequests: Bool
    let mode: String
    let automaticActivation: Bool
    let showInMenuBar: Bool
    let idleMinutes: Double
    let remainingSeconds: Int
    let starting: Bool
    let stopping: Bool
    let canStart: Bool
    let error: String?
}

struct ControlReply {
    let code: Int
    let body: String

    init<T: Encodable>(code: Int, value: T) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.code = code
        body = String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

enum ControlError: Error {
    case invalidCommand, unavailable
}
