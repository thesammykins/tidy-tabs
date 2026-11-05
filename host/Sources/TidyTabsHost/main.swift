// Chromium native messaging host: Aside starts this per message (chrome.runtime.sendNativeMessage), writes one
// length-prefixed JSON request to stdin, and reads one length-prefixed JSON response from stdout.
//
// Requests:
//   {"type": "status"}
//   {"type": "tidy", "tabs": [{"title": "...", "address": "site.com/path"}]}
//   {"type": "assign", "tab": {"title": "...", "address": "..."}, "groups": [{"title": "Lisbon trip", "tabs": ["tab title", ...]}]}
// Responses:
//   {"ok": true}
//   {"ok": true, "groups": [{"title": "Lisbon trip", "tabs": [1, 3], "icon": "suitcase"}]}
//   {"ok": true, "group": 1}  (0-based index into the request's groups; absent when none fits)
//   {"ok": false, "error": "..."}
import Foundation

struct Request: Decodable {
    struct Tab: Decodable {
        var title: String
        var address: String
        var line: String { "\(title.prefix(90)) (\(address.prefix(70)))" }
    }
    struct Group: Decodable { var title: String; var tabs: [String] }
    var type: String
    var tabs: [Tab]?
    var tab: Tab?
    var groups: [Group]?
}

struct Response: Encodable {
    var ok: Bool
    var groups: [TabGroup]?
    var group: Int?
    var error: String?
}

// The on-device model's context is small; the extension also caps it, this guards against a bad request.
let maxTabs = 50
let maxGroups = 20

func readMessage() throws -> Data {
    let header = FileHandle.standardInput.readData(ofLength: 4)
    guard header.count == 4 else { throw HostError("No request on stdin.") }
    let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    guard length <= 1_048_576 else { throw HostError("Request too large.") }
    let body = FileHandle.standardInput.readData(ofLength: Int(length))
    guard body.count == Int(length) else { throw HostError("Request was cut short.") }
    return body
}

func write(_ response: Response) {
    let body = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"Couldn't encode the response."}"#.utf8)
    var length = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
    FileHandle.standardOutput.write(body)
}

struct HostError: Error, LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func handle(_ request: Request) async throws -> Response {
    if let reason = Model.unavailableReason() { return Response(ok: false, error: reason) }
    switch request.type {
    case "status":
        return Response(ok: true)
    case "tidy":
        let lines = (request.tabs ?? []).prefix(maxTabs).map(\.line)
        guard lines.count >= 2 else { return Response(ok: false, error: "There are no loose tabs to tidy.") }
        let plan = try await Model.plan(for: Array(lines))
        guard !plan.isEmpty else { return Response(ok: true, groups: []) }
        let choices = try await Model.sort(Array(lines), into: plan.map(\.name))
        let groups = Grouping.groups(fromChoices: choices, plan: plan)
        return Response(ok: true, groups: groups)
    case "assign":
        // The extension only sends named groups; the model can't match a tab to a group without a name.
        let groups = Array((request.groups ?? []).prefix(maxGroups))
        guard let tab = request.tab, !groups.isEmpty else { return Response(ok: true) }
        let index = try await Model.assign(tab: tab.line, to: groups.map { ($0.title, $0.tabs.map { String($0.prefix(90)) }) })
        return Response(ok: true, group: index)
    default:
        return Response(ok: false, error: "Unknown request type \(request.type).")
    }
}

func respond(_ response: Response) {
    Log.write("response: \(String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self))")
    write(response)
}

do {
    let body = try readMessage()
    Log.write("request: \(String(decoding: body, as: UTF8.self))")
    respond(try await handle(try JSONDecoder().decode(Request.self, from: body)))
} catch {
    respond(Response(ok: false, error: "The model couldn't group these tabs: \(error.localizedDescription)"))
}
