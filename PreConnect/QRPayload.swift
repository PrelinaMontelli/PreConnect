//
//  QRPayload.swift
//  PreConnect 的二维码载荷解析
//  Created by Prelina Montelli
//

import Foundation

/// Decoded + validated payload from a preconnect/pair QR code.
// MARK: - 二维码载荷

struct QRPayload {
    let type: String
    let endpointURL: URL        // e.g. http://host:5005/api/pair
    let pin: String
    let rotatingKey: String
    let expires: Date
    let server: String?         // optional display name

    // MARK: - 派生属性

    /// Service root URL derived from the pair endpoint (strips /api/pair → /)
    var serviceBaseURL: URL {
        var comps = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        comps.path  = "/"
        comps.query = nil
        return comps.url ?? endpointURL
    }

    var secondsUntilExpiry: TimeInterval { expires.timeIntervalSinceNow }

    // MARK: - 二维码错误

    enum QRError: LocalizedError {
        case invalidJSON
        case wrongType
        case missingField(String)
        case invalidEndpoint
        case expired

        var errorDescription: String? {
            switch self {
            case .invalidJSON:          return "无法识别此二维码，请扫描 PreConnect 专用二维码"
            case .wrongType:            return "二维码类型不匹配，请使用 PreConnect 专用二维码"
            case .missingField(let f):  return "二维码缺少必填字段：\(f)"
            case .invalidEndpoint:      return "二维码中的服务地址格式无效（需以 http 开头）"
            case .expired:              return "二维码已过期，请在主机端刷新后重新扫码"
            }
        }
    }

    // MARK: - 解析与校验

    private static func normalizeRawPayload(_ raw: String) -> String {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        debugQR("normalize: rawLength=\(raw.count)")

        // Allow copied payloads that end with a semicolon.
        if candidate.hasSuffix(";") {
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            debugQR("normalize: removed trailing semicolon")
        }

        // If extra prefix/suffix text exists, keep the JSON object block only.
        if let firstBrace = candidate.firstIndex(of: "{"),
           let lastBrace = candidate.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            candidate = String(candidate[firstBrace...lastBrace])
            debugQR("normalize: extracted JSON object block")
        }

        return candidate
    }

    private static func parseExpiry(_ exStr: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: exStr) {
            return date
        }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: exStr) {
            return date
        }

        // Fallback for timestamps like 2026-03-18T18:56:16.2069831+00:00 (7 fractional digits).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX"
        if let date = formatter.date(from: exStr) {
            return date
        }

        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.date(from: exStr)
    }

    /// Parse a raw QR string. Throws `QRError` on validation failure.
    /// - Parameter clockSkewTolerance: Extra seconds tolerated when checking expiry (default 120 s).
    static func parse(from raw: String, clockSkewTolerance: TimeInterval = 120) throws -> QRPayload {
        let normalized = normalizeRawPayload(raw)
        debugQR("parse: normalizedLength=\(normalized.count)")

        guard let data = normalized.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            debugQR("parse failed: invalidJSON")
            throw QRError.invalidJSON
        }

        guard let type = obj["type"] as? String else {
            debugQR("parse failed: missingField(type)")
            throw QRError.missingField("type")
        }
        guard type == "preconnect/pair" else {
            debugQR("parse failed: wrongType=\(type)")
            throw QRError.wrongType
        }
        guard let epStr = obj["endpoint"] as? String else {
            debugQR("parse failed: missingField(endpoint)")
            throw QRError.missingField("endpoint")
        }
        guard let pin = obj["pin"] as? String else {
            debugQR("parse failed: missingField(pin)")
            throw QRError.missingField("pin")
        }
        guard let rk = obj["rotatingKey"] as? String else {
            debugQR("parse failed: missingField(rotatingKey)")
            throw QRError.missingField("rotatingKey")
        }
        guard let exStr = obj["expires"] as? String else {
            debugQR("parse failed: missingField(expires)")
            throw QRError.missingField("expires")
        }

        // Validate endpoint: must be valid URL with http/https scheme and a host
        guard let epURL = URL(string: epStr),
              (epURL.scheme == "http" || epURL.scheme == "https"),
              epURL.host != nil
        else {
            debugQR("parse failed: invalidEndpoint=\(epStr)")
            throw QRError.invalidEndpoint
        }

        guard let expiresDate = parseExpiry(exStr) else {
            debugQR("parse failed: invalid expires format=\(exStr)")
            throw QRError.missingField("expires（格式无效）")
        }

        // Allow ±clockSkewTolerance for client clock drift
        guard Date() <= expiresDate.addingTimeInterval(clockSkewTolerance) else {
            debugQR("parse failed: expired now=\(Date()) expires=\(expiresDate) tolerance=\(Int(clockSkewTolerance))")
            throw QRError.expired
        }

        debugQR("parse success: endpointHost=\(epURL.host ?? "nil"), pinLen=\(pin.count), rotatingKeyLen=\(rk.count)")

        return QRPayload(
            type:        type,
            endpointURL: epURL,
            pin:         pin,
            rotatingKey: rk,
            expires:     expiresDate,
            server:      obj["server"] as? String
        )
    }

    private static func debugQR(_ message: String) {
#if DEBUG
        print("[QR][QRPayload] \(message)")
#endif
    }
}
