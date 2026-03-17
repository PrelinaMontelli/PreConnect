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

    /// Parse a raw QR string. Throws `QRError` on validation failure.
    /// - Parameter clockSkewTolerance: Extra seconds tolerated when checking expiry (default 120 s).
    static func parse(from raw: String, clockSkewTolerance: TimeInterval = 120) throws -> QRPayload {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw QRError.invalidJSON }

        guard let type = obj["type"] as? String       else { throw QRError.missingField("type") }
        guard type == "preconnect/pair"                else { throw QRError.wrongType }
        guard let epStr = obj["endpoint"] as? String  else { throw QRError.missingField("endpoint") }
        guard let pin   = obj["pin"]  as? String      else { throw QRError.missingField("pin") }
        guard let rk    = obj["rotatingKey"] as? String else { throw QRError.missingField("rotatingKey") }
        guard let exStr = obj["expires"] as? String   else { throw QRError.missingField("expires") }

        // Validate endpoint: must be valid URL with http/https scheme and a host
        guard let epURL = URL(string: epStr),
              (epURL.scheme == "http" || epURL.scheme == "https"),
              epURL.host != nil
        else { throw QRError.invalidEndpoint }

        // Parse ISO8601 date (with and without fractional seconds)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expires = iso.date(from: exStr)
        if expires == nil {
            iso.formatOptions = [.withInternetDateTime]
            expires = iso.date(from: exStr)
        }
        guard let expiresDate = expires else { throw QRError.missingField("expires（格式无效）") }

        // Allow ±clockSkewTolerance for client clock drift
        guard Date() <= expiresDate.addingTimeInterval(clockSkewTolerance) else { throw QRError.expired }

        return QRPayload(
            type:        type,
            endpointURL: epURL,
            pin:         pin,
            rotatingKey: rk,
            expires:     expiresDate,
            server:      obj["server"] as? String
        )
    }
}
