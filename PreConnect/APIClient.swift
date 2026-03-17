//
//  APIClient.swift
//  PreConnect 的网络请求客户端
//  Created by Prelina Montelli
//

import Foundation

// MARK: - 网络错误

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case serverError(code: Int, message: String)
    case unauthorized        // 401 — session expired or revoked
    case pinOrKeyInvalid     // 400 from QR pair — bad PIN or rotating key

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:      return "服务地址无效"
        case .invalidResponse:     return "服务器响应解析失败"
        case .unauthorized:        return "认证失败，会话已过期"
        case .pinOrKeyInvalid:     return "PIN 或密钥已失效，请刷新二维码后重试"
        case let .serverError(code, message): return "HTTP \(code): \(message)"
        }
    }
}

// MARK: - 网络客户端

struct APIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 公开接口

    func ping(baseURL: URL) async throws -> PingResponse {
        try await request(baseURL: baseURL, path: "api/ping", method: "GET", body: Optional<String>.none, token: nil)
    }

    func status(baseURL: URL) async throws -> StatusResponse {
        try await request(baseURL: baseURL, path: "api/status", method: "GET", body: Optional<String>.none, token: nil)
    }

    func pair(baseURL: URL, payload: PairRequest) async throws -> PairResponse {
        try await request(baseURL: baseURL, path: "api/pair", method: "POST", body: payload, token: nil)
    }

    func telemetry(baseURL: URL, token: String) async throws -> TelemetryResponse {
        try await request(baseURL: baseURL, path: "api/telemetry", method: "GET", body: Optional<String>.none, token: token)
    }

    // MARK: - 核心请求方法

    private func request<T: Decodable, Body: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIClientError.invalidBaseURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            req.setValue(token, forHTTPHeaderField: "X-Session-Token")
        }

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIClientError.unauthorized }
            let message = parseErrorMessage(from: data) ?? "请求失败"
            throw APIClientError.serverError(code: http.statusCode, message: message)
        }

        do {
            return try JSONDecoder.preconnect.decode(T.self, from: data)
        } catch {
            throw APIClientError.invalidResponse
        }
    }

    // MARK: - 二维码配对接口

    /// Direct pair to a fully-qualified endpoint URL (used for QR pairing where the endpoint
    /// already includes the path, e.g. http://host:5005/api/pair).
    func pairDirect(endpoint: URL, payload: PairRequest) async throws -> PairResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }

        switch http.statusCode {
        case 200:
            do { return try JSONDecoder.preconnect.decode(PairResponse.self, from: data) }
            catch { throw APIClientError.invalidResponse }
        case 400:
            throw APIClientError.pinOrKeyInvalid
        case 401:
            throw APIClientError.unauthorized
        default:
            let message = parseErrorMessage(from: data) ?? "请求失败"
            throw APIClientError.serverError(code: http.statusCode, message: message)
        }
    }

    // MARK: - 辅助方法

    private func parseErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["error"] as? String
        else {
            return nil
        }
        return message
    }
}

// MARK: - 解码器配置

extension JSONDecoder {
    static let preconnect: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
