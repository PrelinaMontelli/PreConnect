import Foundation
import UIKit
import Combine

// MARK: - QR Scan Phase

enum QRScanPhase {
    case idle
    case scanning
    case pairing(QRPayload)
    case success
    case failed(String)
}

// MARK: - AppViewModel

@MainActor
final class AppViewModel: ObservableObject {
    static let defaultPollingInterval: TimeInterval = 2

    @Published var baseURLText: String = "http://127.0.0.1:5005/"
    @Published var pin: String = ""
    @Published var status: StatusResponse?
    @Published var session: SessionInfo?
    @Published var snapshot: HardwareSnapshot?
    @Published private(set) var sensorHistory: [String: [MetricSample]] = [:]
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var pollingInterval: TimeInterval = defaultPollingInterval
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var qrPhase: QRScanPhase = .idle
    @Published var cameraError: String?

    private let client = APIClient()
    private var pollTask: Task<Void, Never>?
    private let localDeviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let localDeviceName = UIDevice.current.name

    var isPaired: Bool { session != nil }

    var flattenedSensors: [SensorDisplayItem] {
        guard let snapshot else { return [] }
        return snapshot.components
            .flatMap(\.allComponents)
            .flatMap { component in
                component.sensors.map { sensor in
                    SensorDisplayItem(
                        id: sensor.sensorId,
                        componentName: component.hardwareName,
                        sensorName: sensor.sensorName,
                        sensorType: sensor.sensorType,
                        value: sensor.value,
                        min: sensor.min,
                        max: sensor.max,
                        hardwarePath: sensor.hardwarePath
                    )
                }
            }
    }

    var availableSensors: [SensorDisplayItem] {
        flattenedSensors.filter { $0.value != nil }
    }

    var chartableSensors: [SensorDisplayItem] {
        flattenedSensors
            .sorted { lhs, rhs in
                if (lhs.value != nil) != (rhs.value != nil) {
                    return lhs.value != nil
                }
                if lhs.componentName != rhs.componentName {
                    return lhs.componentName < rhs.componentName
                }
                return lhs.sensorName < rhs.sensorName
            }
    }

    var sensorsByCategory: [(category: SensorCategory, sensors: [SensorDisplayItem])] {
        SensorCategory.allCases.compactMap { category in
            let sensors = chartableSensors.filter { $0.category == category }
            return sensors.isEmpty ? nil : (category, sensors)
        }
    }

    var dashboardFacts: [DashboardFact] {
        var facts: [DashboardFact] = []

        if let machineName = status?.machineName ?? session?.serverName {
            facts.append(DashboardFact(id: "host", title: "主机", value: machineName, symbolName: "desktopcomputer"))
        }

        if let endpoint = session?.endpoint.host ?? URL(string: status?.endpoint ?? "")?.host {
            facts.append(DashboardFact(id: "endpoint", title: "端点", value: endpoint, symbolName: "network"))
        }

        if let activeConnections = status?.activeConnections {
            facts.append(DashboardFact(id: "connections", title: "活跃连接", value: "\(activeConnections)", symbolName: "dot.radiowaves.left.and.right"))
        }

        if let expires = session?.expiresAt {
            facts.append(
                DashboardFact(
                    id: "session-expiry",
                    title: "会话到期",
                    value: expires.formatted(date: .omitted, time: .shortened),
                    symbolName: "key.fill"
                )
            )
        }

        if let lastUpdatedAt {
            facts.append(
                DashboardFact(
                    id: "updated",
                    title: "最近更新",
                    value: lastUpdatedAt.formatted(date: .omitted, time: .standard),
                    symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
            )
        }

        facts.append(
            DashboardFact(
                id: "sensors",
                title: "传感器",
                value: "\(flattenedSensors.count)",
                symbolName: "sensor.tag.radiowaves.forward"
            )
        )

        facts.append(
            DashboardFact(
                id: "polling-interval",
                title: "轮询速率",
                value: pollingIntervalText,
                symbolName: "timer"
            )
        )

        return facts
    }

    var pollingIntervalText: String {
        if pollingInterval < 1 {
            return String(format: "%.1f 秒", pollingInterval)
        }
        return String(format: "%.0f 秒", pollingInterval)
    }

    // MARK: - Init (restore persisted session)

    init() {
        if let persisted = PersistedSession.restore(),
           let info = persisted.toSessionInfo() {
            let isValid = info.expiresAt.map { $0 > Date() } ?? true
            if isValid {
                session = info
                Task {
                    startPolling()
                    await refreshTelemetryOnce()
                }
            } else {
                PersistedSession.wipe()
            }
        }
    }

    // MARK: - Manual Connection

    func pingAndLoadStatus() async {
        do {
            isLoading = true
            errorMessage = nil
            let baseURL = try normalizedBaseURL()
            _ = try await client.ping(baseURL: baseURL)
            status = try await client.status(baseURL: baseURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func pair() async {
        do {
            isLoading = true
            errorMessage = nil

            let baseURL = try normalizedBaseURL()
            let response = try await client.pair(
                baseURL: baseURL,
                payload: PairRequest(pin: pin, deviceId: localDeviceId, name: localDeviceName)
            )

            let endpointURL = URL(string: response.endpoint) ?? baseURL
            let expiresAt = ISO8601DateFormatter().date(from: response.sessionTokenExpiresUtc ?? "")

            session = SessionInfo(
                token: response.sessionToken,
                expiresAt: expiresAt,
                serverName: response.serverName,
                endpoint: endpointURL,
                deviceId: response.deviceId,
                deviceName: response.deviceName
            )

            PersistedSession(
                token: response.sessionToken,
                expiresAtISO: response.sessionTokenExpiresUtc,
                serverName: response.serverName,
                endpointString: endpointURL.absoluteString,
                deviceId: response.deviceId,
                deviceName: response.deviceName
            ).persist()

            startPolling()
            await refreshTelemetryOnce()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - QR Pairing

    func startQRScanning() {
        cameraError = nil
        qrPhase = .scanning
    }

    func handleQRFound(_ raw: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            let payload = try QRPayload.parse(from: raw)
            qrPhase = .pairing(payload)
            Task { await pairWithQR(payload: payload) }
        } catch {
            qrPhase = .failed(error.localizedDescription)
        }
    }

    func cancelQRScan() {
        qrPhase = .idle
        cameraError = nil
    }

    func resetQRScan() {
        cameraError = nil
        qrPhase = .scanning
    }

    func pairWithQR(payload: QRPayload) async {
        do {
            let pairReq = PairRequest(
                pin: payload.pin,
                deviceId: localDeviceId,
                name: localDeviceName,
                rotatingKey: payload.rotatingKey
            )
            let response = try await client.pairDirect(endpoint: payload.endpointURL, payload: pairReq)

            let endpointURL = URL(string: response.endpoint) ?? payload.serviceBaseURL
            let expiresAt = ISO8601DateFormatter().date(from: response.sessionTokenExpiresUtc ?? "")

            session = SessionInfo(
                token: response.sessionToken,
                expiresAt: expiresAt,
                serverName: response.serverName,
                endpoint: endpointURL,
                deviceId: response.deviceId,
                deviceName: response.deviceName
            )

            // Never log the token
            PersistedSession(
                token: response.sessionToken,
                expiresAtISO: response.sessionTokenExpiresUtc,
                serverName: response.serverName,
                endpointString: endpointURL.absoluteString,
                deviceId: response.deviceId,
                deviceName: response.deviceName
            ).persist()

            qrPhase = .success
            startPolling()
            await refreshTelemetryOnce()

        } catch let err as APIClientError {
            switch err {
            case .pinOrKeyInvalid:
                qrPhase = .failed("PIN 或密钥已失效，请刷新二维码后重试")
            case .serverError(let code, _) where code >= 500:
                qrPhase = .failed("服务端异常，请稍后重试")
            default:
                qrPhase = .failed(err.localizedDescription)
            }
        } catch let err as URLError {
            switch err.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                qrPhase = .failed("网络不可达，请检查 Wi-Fi 连接后重试")
            default:
                qrPhase = .failed(err.localizedDescription)
            }
        } catch {
            qrPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Telemetry

    func refreshTelemetryOnce() async {
        guard let session else { return }

        do {
            isLoading = true
            errorMessage = nil
            let data = try await client.telemetry(baseURL: session.endpoint, token: session.token)
            snapshot = data.snapshot
            lastUpdatedAt = Date()

            if let snapshot = data.snapshot {
                updateMetricHistory(using: snapshot)
            }
        } catch APIClientError.unauthorized {
            handleSessionExpired()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func handleSessionExpired() {
        pollTask?.cancel()
        session = nil
        snapshot = nil
        sensorHistory = [:]
        PersistedSession.wipe()
        errorMessage = "会话已过期，请重新扫码配对"
    }

    func disconnect() {
        pollTask?.cancel()
        session = nil
        snapshot = nil
        status = nil
        sensorHistory = [:]
        lastUpdatedAt = nil
        PersistedSession.wipe()
    }

    func updatePollingInterval(_ seconds: TimeInterval) {
        let normalized = max(0.5, seconds)
        guard abs(pollingInterval - normalized) > 0.001 else { return }
        pollingInterval = normalized

        if isPaired {
            startPolling()
        }
    }

    func chartStates(for sensorIDs: [String]) -> [SensorChartState] {
        sensorIDs.compactMap { sensorID in
            guard let sensor = chartableSensors.first(where: { $0.id == sensorID }) else { return nil }
            return SensorChartState(
                sensorId: sensor.id,
                sensorName: sensor.chartDisplayName,
                componentName: sensor.chartSubtitle,
                sensorType: sensor.sensorType,
                currentValue: sensor.value,
                samples: sensorHistory[sensor.id] ?? []
            )
        }
    }

    func widgetStates(for configs: [DashboardWidgetConfig]) -> [DashboardWidgetState] {
        configs.compactMap { config in
            guard let sensor = chartableSensors.first(where: { $0.id == config.sensorId }) else { return nil }
            return DashboardWidgetState(config: config, sensor: sensor, samples: sensorHistory[sensor.id] ?? [])
        }
    }

    func canFitWidgets(_ configs: [DashboardWidgetConfig]) -> Bool {
        DashboardLayoutEngine.canFit(configs)
    }

    func defaultChartSensorIDs(limit: Int = 6) -> [String] {
        availableSensors
            .sorted { lhs, rhs in chartPriority(for: lhs) > chartPriority(for: rhs) }
            .prefix(limit)
            .map(\.id)
    }

    func defaultWidgetConfigs(limit: Int = 6) -> [DashboardWidgetConfig] {
        availableSensors
            .sorted { lhs, rhs in chartPriority(for: lhs) > chartPriority(for: rhs) }
            .prefix(limit)
            .map { sensor in
                let mode: DashboardWidgetDisplayMode = sensor.supportedDisplayModes.contains(.progress) ? .progress : .value
                return DashboardWidgetConfig(sensorId: sensor.id, displayMode: mode)
            }
    }

    func sensors(in section: SensorSection) -> [SensorDisplayItem] {
        flattenedSensors
            .filter { $0.section == section }
            .sorted { lhs, rhs in
                (lhs.value ?? 0) > (rhs.value ?? 0)
            }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTelemetryOnce()
                let interval = self?.pollingInterval ?? Self.defaultPollingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func normalizedBaseURL() throws -> URL {
        var text = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text) else { throw APIClientError.invalidBaseURL }
        return url
    }

    private func updateMetricHistory(using snapshot: HardwareSnapshot) {
        let sensors = snapshot.components
            .flatMap(\.allComponents)
            .flatMap { component in
                component.sensors.map { sensor in
                    SensorDisplayItem(
                        id: sensor.sensorId,
                        componentName: component.hardwareName,
                        sensorName: sensor.sensorName,
                        sensorType: sensor.sensorType,
                        value: sensor.value,
                        min: sensor.min,
                        max: sensor.max,
                        hardwarePath: sensor.hardwarePath
                    )
                }
            }

        let now = Date()

        var nextHistory = sensorHistory
        let activeSensorIDs = Set(sensors.compactMap { sensor in
            sensor.value == nil ? nil : sensor.id
        })

        for sensor in sensors {
            guard let value = sensor.value else { continue }
            var samples = nextHistory[sensor.id] ?? []
            samples.append(MetricSample(timestamp: now, value: value))
            if samples.count > 45 {
                samples.removeFirst(samples.count - 45)
            }
            nextHistory[sensor.id] = samples
        }

        sensorHistory = nextHistory.filter { activeSensorIDs.contains($0.key) }
    }

    private func chartPriority(for item: SensorDisplayItem) -> Int {
        var score = 0
        let text = item.searchText

        switch item.sensorType {
        case 5: score += 60
        case 4: score += 40
        case 2: score += 35
        case 7: score += 30
        case 14: score += 25
        default: score += 10
        }

        if text.contains("cpu") { score += 30 }
        if text.contains("gpu") { score += 30 }
        if text.contains("memory") || text.contains("ram") { score += 25 }
        if text.contains("total") || text.contains("package") || text.contains("core") { score += 10 }

        return score
    }
}
