import Foundation
import AppKit
import CoreGraphics

/// Sends messages (optionally with a screenshot) to a Discord channel through a webhook URL.
/// The URL is stored in the macro's settings on this Mac only. Empty URL = nothing is sent.
enum Discord {
    static func send(_ text: String, image: CGImage? = nil, webhook: String) {
        let hook = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hook.hasPrefix("https://discord.com/api/webhooks/") || hook.hasPrefix("https://discordapp.com/api/webhooks/"),
              let url = URL(string: hook) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
            if let err { DebugLog.append("Discord send failed: \(err.localizedDescription)") }
            else if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                DebugLog.append("Discord send failed: HTTP \(h.statusCode)")
            }
        }.resume()
    }
}
