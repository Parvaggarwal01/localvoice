import Foundation

/// Minimal Slack Web API client for the meetings contract. Foundation only, so tests can run it
/// against a mocked URLSession.
struct SlackClient {
    let token: String
    var session: URLSession = .shared
    var baseURL = URL(string: "https://slack.com/api/")!

    struct AuthInfo: Equatable {
        let team: String
        let user: String
    }

    func authTest() async throws -> AuthInfo {
        let json = try await call("auth.test", form: [:])
        return AuthInfo(team: json["team"] as? String ?? "?", user: json["user"] as? String ?? "?")
    }

    /// Returns the message ts.
    func postMessage(channel: String, text: String) async throws -> String {
        let json = try await call("chat.postMessage", json: ["channel": channel, "text": text, "unfurl_links": false, "unfurl_media": false])
        guard let ts = json["ts"] as? String else { throw SlackError.invalidResponse }
        return ts
    }

    func updateMessage(channel: String, ts: String, text: String) async throws {
        _ = try await call("chat.update", json: ["channel": channel, "ts": ts, "text": text])
    }

    /// Slack's external upload flow: getUploadURLExternal → POST bytes → completeUploadExternal.
    /// Returns the file ID.
    func uploadFile(channelID: String, filename: String, title: String, data: Data, initialComment: String) async throws -> String {
        let ticket = try await call("files.getUploadURLExternal", form: ["filename": filename, "length": String(data.count)])
        guard let uploadURLString = ticket["upload_url"] as? String, let uploadURL = URL(string: uploadURLString),
              let fileID = ticket["file_id"] as? String else { throw SlackError.invalidResponse }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 300
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, uploadResponse) = try await session.upload(for: upload, from: data)
        guard let http = uploadResponse as? HTTPURLResponse else { throw SlackError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SlackError.http(http.statusCode) }

        let filesJSON = String(decoding: try JSONSerialization.data(withJSONObject: [["id": fileID, "title": title]]), as: UTF8.self)
        _ = try await call("files.completeUploadExternal", form: [
            "files": filesJSON,
            "channel_id": channelID,
            "initial_comment": initialComment
        ])
        return fileID
    }

    // MARK: Transport

    private func call(_ method: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return try await send(request)
    }

    private func call(_ method: String, json: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SlackError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SlackError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SlackError.invalidResponse }
        guard json["ok"] as? Bool == true else { throw SlackError.api(json["error"] as? String ?? "unknown_error") }
        return json
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

enum SlackError: LocalizedError, Equatable {
    case api(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .api("not_in_channel"): "The Helm bot is not in that channel. Invite @Helm to it."
        case .api("channel_not_found"): "Slack can’t find that channel ID, or the bot can’t see it."
        case .api("invalid_auth"), .api("not_authed"): "The Slack bot token is not valid."
        case .api("missing_scope"): "The Slack token is missing a scope (needs chat:write and files:write)."
        case .api(let code): "Slack error: \(code)"
        case .http(let status): "Slack returned HTTP \(status)."
        case .invalidResponse: "Slack returned an invalid response."
        }
    }
}

enum AgendaSync {
    /// Edits this device's agenda message in place; posts a new one when there is no saved ts or the
    /// edit fails (contract section 1). Returns the ts to save.
    static func publish(client: SlackClient, channel: String, text: String, savedTS: String?) async throws -> String {
        if let savedTS, !savedTS.isEmpty {
            do {
                try await client.updateMessage(channel: channel, ts: savedTS, text: text)
                return savedTS
            } catch {
                // Message deleted, channel changed, or edit window closed: fall through and post anew.
            }
        }
        return try await client.postMessage(channel: channel, text: text)
    }
}
