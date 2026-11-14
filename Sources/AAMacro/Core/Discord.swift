import Foundation
import AppKit
import CoreGraphics

/// Sends messages (optionally with a screenshot) to a Discord channel through a webhook URL.
/// The URL is stored in the macro's settings on this Mac only.
///
/// Every failure is reported — to the log file, and to `done` if the caller passes one. A send
/// that quietly does nothing is worse than no alerts at all: you only find out you missed a
/// secret after it has already gone by.
enum Discord {

    /// - Parameter done: called on the main actor with nil on success, or why it failed.
    static func send(_ text: String, image: CGImage? = nil, webhook: String,
                     done: (@Sendable (String?) -> Void)? = nil) {
        func report(_ why: String?) {
            if let why { DebugLog.append("Discord: \(why)") }
            if let done { DispatchQueue.main.async { done(why) } }
        }
        let hook = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.isEmpty else { return report("no webhook URL set in Settings") }
        guard hook.hasPrefix("https://discord.com/api/webhooks/")
                || hook.hasPrefix("https://discordapp.com/api/webhooks/") else {
            return report("that URL doesn't look like a webhook — it has to start with https://discord.com/api/webhooks/")
        }
        guard let url = URL(string: hook) else { return report("the webhook URL couldn't be read (stray spaces or characters?)") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        let payload = try? JSONSerialization.data(withJSONObject: ["content": String(text.prefix(1900)),
                                                                   "username": "AA Macro ♡"])
        if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let boundary = "aamacro-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func add(_ s: String) { body.append(Data(s.utf8)) }
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
            body.append(payload ?? Data("{}".utf8)); add("\r\n")
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"screen.png\"\r\nContent-Type: image/png\r\n\r\n")
            body.append(png); add("\r\n--\(boundary)--\r\n")
            req.httpBody = body
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload
        }
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                report("couldn't reach Discord — \(err.localizedDescription)")
            } else if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                switch h.statusCode {
                case 401, 403: report("Discord refused it (HTTP \(h.statusCode)) — the webhook URL is wrong")
                case 404:      report("Discord says that webhook doesn't exist (HTTP 404) — it was deleted, or the URL is wrong")
                case 429:      report("Discord is rate-limiting the webhook (HTTP 429) — this message was dropped")
                default:       report("Discord returned HTTP \(h.statusCode)")
                }
            } else {
                report(nil)
            }
        }.resume()
    }
}
