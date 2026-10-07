import AppKit
import Foundation
import os.log

private let visualPointerLog = OSLog(subsystem: "com.williamh07.wisper", category: "VisualPointer")

struct VisualGroundingTarget {
    let screenRect: NSRect
    let label: String
}

final class VisualPointerService {
    static let shared = VisualPointerService()

    /// Configurable request timeout (in seconds) for Visual Pointer grounding requests.
    var requestTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "visual_pointer_timeout_seconds")
        guard override.isFinite, override > 0 else { return 15 }
        return min(max(override, 5), 60)
    }

    private let maxScreenshotDimension: CGFloat = 1280
    private let compressionQuality: Double = 0.65

    /// Determines whether the transcript text represents an on-screen localization query.
    static func isVisualPointerQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        let patterns = [
            "où se trouve",
            "où est",
            "où sont",
            "c'est où",
            "montre-moi",
            "montre moi",
            "trouve-moi",
            "trouve moi",
            "trouve le",
            "trouve la",
            "trouve les",
            "trouve l'",
            "trouve un",
            "trouve une",
            "repère le",
            "repère la",
            "repère",
            "indique-moi",
            "indique moi",
            "where is",
            "where are",
            "where's",
            "find the",
            "find a",
            "show me",
            "locate the"
        ]

        for pattern in patterns {
            if lower.hasPrefix(pattern) { return true }
        }

        if lower.contains("où se trouve") || lower.contains("où est le") || lower.contains("où est la") || lower.contains("où est l'") {
            return true
        }

        return false
    }

    /// Captures the main screen and queries Gemini for the element's bounding box.
    func locateElement(
        query: String,
        apiKey: String,
        model: String = "google/gemini-2.5-flash"
    ) async throws -> VisualGroundingTarget? {
        if await LLMCooldownManager.shared.isInCooldown(model) {
            os_log(.info, log: visualPointerLog, "VisualPointer model %{public}@ is in cooldown, skipping grounding request", model)
            return nil
        }

        guard let screen = NSScreen.main else {
            os_log(.error, log: visualPointerLog, "No main screen found")
            return nil
        }

        // 1. Capture screen image
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID?,
              let cgImage = CGDisplayCreateImage(displayID) else {
            os_log(.error, log: visualPointerLog, "Failed to capture main display image")
            return nil
        }

        let screenFrame = screen.frame
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // 2. Encode to compressed JPEG Data URL
        guard let dataURL = makeCompressedDataURL(from: cgImage) else {
            os_log(.error, log: visualPointerLog, "Failed to encode screenshot to JPEG data URL")
            return nil
        }

        os_log(.info, log: visualPointerLog, "Screenshot captured: %dx%d, encoded to base64", Int(imageWidth), Int(imageHeight))

        // 3. Send grounding request to Gemini 2.5 Flash via OpenRouter
        let target = try await queryGroundingAPI(
            query: query,
            dataURL: dataURL,
            apiKey: apiKey,
            model: model,
            screenFrame: screenFrame
        )

        return target
    }

    private func queryGroundingAPI(
        query: String,
        dataURL: String,
        apiKey: String,
        model: String,
        screenFrame: NSRect
    ) async throws -> VisualGroundingTarget? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Wisper-Assistant", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Wisper", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = requestTimeoutSeconds

        let systemPrompt = """
        You are an ultra-precise macOS visual grounding assistant.
        The user wants to locate an element on their screen based on their question.
        Analyze the provided screenshot carefully to find the button, menu item, icon, text, link, or input field.

        You MUST respond ONLY with a raw JSON object (no markdown, no backticks):
        {
          "found": true,
          "box_2d": [ymin, xmin, ymax, xmax],
          "label": "Short name of the found element"
        }
        or if the element is not found on screen:
        {
          "found": false,
          "label": "Element not found"
        }

        Coordinates ymin, xmin, ymax, xmax must be integer numbers from 0 to 1000 representing the exact bounding box [top, left, bottom, right] of the element in the image.
        """

        let userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": "Question: \(query)"
            ],
            [
                "type": "image_url",
                "image_url": ["url": dataURL]
            ]
        ]

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await LLMAPITransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        if httpResponse.statusCode == 429 {
            let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
            await LLMCooldownManager.shared.setCooldown(model, retryAfterSeconds: cooldown.seconds, persist: cooldown.isDaily)
            os_log(.info, log: visualPointerLog, "VisualPointer model %{public}@ hit 429 rate limit. Cooldown: %.1fs (daily: %{public}@)", model, cooldown.seconds, String(describing: cooldown.isDaily))
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            os_log(.error, log: visualPointerLog, "OpenRouter error HTTP %d: %{public}@", httpResponse.statusCode, errorText)
            return nil
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            return nil
        }

        os_log(.info, log: visualPointerLog, "Grounding raw response: %{public}@", rawContent)

        return parseGroundingResponse(rawContent, screenFrame: screenFrame)
    }

    private func parseGroundingResponse(_ content: String, screenFrame: NSRect) -> VisualGroundingTarget? {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let found = dict["found"] as? Bool, found else {
            return nil
        }

        guard let box = dict["box_2d"] as? [Any], box.count >= 4 else {
            return nil
        }

        let ymin = (box[0] as? NSNumber)?.doubleValue ?? 0
        let xmin = (box[1] as? NSNumber)?.doubleValue ?? 0
        let ymax = (box[2] as? NSNumber)?.doubleValue ?? 1000
        let xmax = (box[3] as? NSNumber)?.doubleValue ?? 1000
        let label = (dict["label"] as? String) ?? "Élément trouvé"

        let screenW = screenFrame.width
        let screenH = screenFrame.height

        // Calculate horizontal position
        let x = screenFrame.origin.x + (xmin / 1000.0) * screenW
        let rawWidth = ((xmax - xmin) / 1000.0) * screenW
        let width = max(rawWidth, 42.0)

        // Calculate vertical position (AppKit origin is bottom-left, ymin=0 is top)
        let topDistance = (ymin / 1000.0) * screenH
        let rawHeight = ((ymax - ymin) / 1000.0) * screenH
        let height = max(rawHeight, 32.0)
        let y = screenFrame.origin.y + (screenH - topDistance - height)

        let targetRect = NSRect(
            x: max(x, screenFrame.origin.x),
            y: max(y, screenFrame.origin.y),
            width: min(width, screenW),
            height: min(height, screenH)
        )

        return VisualGroundingTarget(screenRect: targetRect, label: label)
    }

    private func makeCompressedDataURL(from image: CGImage) -> String? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let maxDim = max(width, height)

        let targetImage: CGImage
        if maxDim > maxScreenshotDimension {
            let scale = maxScreenshotDimension / maxDim
            let targetWidth = Int(width * scale)
            let targetHeight = Int(height * scale)

            guard let colorSpace = image.colorSpace,
                  let context = CGContext(
                    data: nil,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return nil
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let resized = context.makeImage() else { return nil }
            targetImage = resized
        } else {
            targetImage = image
        }

        let rep = NSBitmapImageRep(cgImage: targetImage)
        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        ) else { return nil }

        let base64 = jpegData.base64EncodedString()
        return "data:image/jpeg;base64,\(base64)"
    }
}
