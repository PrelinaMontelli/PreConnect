//
//  AppViewModel.swift
//  PreConnect 的应用状态与业务逻辑
//  Created by Prelina Montelli
//

import Foundation
import UIKit
import Combine

// MARK: - 二维码扫描状态

enum QRScanPhase {
    case idle
    case scanning
    case pairing(QRPayload)
    case success
    case failed(String)
}

// MARK: - 视图模型

@MainActor
final class AppViewModel: ObservableObject {
    static let defaultPollingInterval: TimeInterval = 2

    // MARK: - 发布状态

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
    @Published private(set) var isDemoMode: Bool = false
    @Published private(set) var flattenedSensorsCache: [SensorDisplayItem] = []
    @Published private(set) var chartableSensorsCache: [SensorDisplayItem] = []
    @Published private(set) var sensorsByCategoryCache: [(category: SensorCategory, sensors: [SensorDisplayItem])] = []

    // MARK: - 私有状态

    private let client = APIClient()
    private var pollTask: Task<Void, Never>?
    private var telemetryPollingEnabled = true
    private let localDeviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let localDeviceName = UIDevice.current.name
    private var demoTick: Double = 0

    private struct TelemetryDerivedData: Sendable {
        let flattenedSensors: [SensorDisplayItem]
        let chartableSensors: [SensorDisplayItem]
        let sensorsByCategory: [(category: SensorCategory, sensors: [SensorDisplayItem])]
        let history: [String: [MetricSample]]
        let updatedAt: Date
    }

    // MARK: - 计算属性

    var isPaired: Bool { session != nil }

    var flattenedSensors: [SensorDisplayItem] {
        flattenedSensorsCache
    }

    var availableSensors: [SensorDisplayItem] {
        flattenedSensors.filter { $0.value != nil }
    }

    var chartableSensors: [SensorDisplayItem] {
        chartableSensorsCache
    }

    var sensorsByCategory: [(category: SensorCategory, sensors: [SensorDisplayItem])] {
        sensorsByCategoryCache
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

    // MARK: - 初始化

    init() {
        if let persisted = PersistedSession.restore(),
           let info = persisted.toSessionInfo() {
            let isValid = info.expiresAt.map { $0 > Date() } ?? true
            if isValid {
                session = info
                telemetryPollingEnabled = true
                Task {
                    startPolling()
                    await refreshTelemetryOnce(showLoadingIndicator: false)
                }
            } else {
                PersistedSession.wipe()
            }
        }
    }

    // MARK: - 手动连接

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
            await refreshTelemetryOnce(showLoadingIndicator: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - 二维码配对

    func startQRScanning() {
        if isDemoMode {
            disconnect()
        }
        debugQR("start scanning")
        cameraError = nil
        qrPhase = .scanning
    }

    func handleQRFound(_ raw: String) {
        debugQR("raw payload received, length=\(raw.count), preview=\(sanitizedPreview(raw))")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            let payload = try QRPayload.parse(from: raw)
            debugQR("payload parsed, host=\(payload.endpointURL.host ?? "nil"), expiresIn=\(Int(payload.secondsUntilExpiry))s")
            qrPhase = .pairing(payload)
            Task { await pairWithQR(payload: payload) }
        } catch {
            debugQR("payload parse failed: \(error.localizedDescription)")
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
            debugQR("pair direct start, endpoint=\(payload.endpointURL.absoluteString)")
            let pairReq = PairRequest(
                pin: payload.pin,
                deviceId: localDeviceId,
                name: localDeviceName,
                rotatingKey: payload.rotatingKey
            )
            let response = try await client.pairDirect(endpoint: payload.endpointURL, payload: pairReq)
            debugQR("pair direct success, server=\(response.serverName), device=\(response.deviceId)")

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
            await refreshTelemetryOnce(showLoadingIndicator: false)

        } catch let err as APIClientError {
            debugQR("pair direct failed(APIClientError): \(err.localizedDescription)")
            switch err {
            case .pinOrKeyInvalid:
                qrPhase = .failed("PIN 或密钥已失效，请刷新二维码后重试")
            case .serverError(let code, _) where code >= 500:
                qrPhase = .failed("服务端异常，请稍后重试")
            default:
                qrPhase = .failed(err.localizedDescription)
            }
        } catch let err as URLError {
            debugQR("pair direct failed(URLError): \(err.code.rawValue) \(err.localizedDescription)")
            switch err.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                qrPhase = .failed("网络不可达，请检查 Wi-Fi 连接后重试")
            default:
                qrPhase = .failed(err.localizedDescription)
            }
        } catch {
            debugQR("pair direct failed(unknown): \(error.localizedDescription)")
            qrPhase = .failed(error.localizedDescription)
        }
    }

    private func sanitizedPreview(_ raw: String, maxLength: Int = 180) -> String {
        let compact = raw
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if compact.count <= maxLength {
            return compact
        }

        return String(compact.prefix(maxLength)) + "..."
    }

    private func debugQR(_ message: String) {
#if DEBUG
        print("[QR][AppViewModel] \(message)")
#endif
    }

    // MARK: - 遥测数据

    func refreshTelemetryOnce(showLoadingIndicator: Bool = false) async {
        guard let session else { return }

        if isDemoMode {
            if showLoadingIndicator {
                isLoading = true
            }
            errorMessage = nil

            let snapshot = generateDemoSnapshot()
            let existingHistory = sensorHistory
            let derived = await Task.detached(priority: .userInitiated) {
                Self.deriveTelemetryData(snapshot: snapshot, existingHistory: existingHistory)
            }.value

            self.snapshot = snapshot
            self.lastUpdatedAt = derived.updatedAt
            self.sensorHistory = derived.history
            self.flattenedSensorsCache = derived.flattenedSensors
            self.chartableSensorsCache = derived.chartableSensors
            self.sensorsByCategoryCache = derived.sensorsByCategory

            if showLoadingIndicator {
                isLoading = false
            }
            return
        }

        do {
            if showLoadingIndicator {
                isLoading = true
            }
            errorMessage = nil
            let data = try await client.telemetry(baseURL: session.endpoint, token: session.token)

            if let snapshot = data.snapshot {
                let existingHistory = sensorHistory
                let derived = await Task.detached(priority: .userInitiated) {
                    Self.deriveTelemetryData(snapshot: snapshot, existingHistory: existingHistory)
                }.value

                self.snapshot = snapshot
                self.lastUpdatedAt = derived.updatedAt
                self.sensorHistory = derived.history
                self.flattenedSensorsCache = derived.flattenedSensors
                self.chartableSensorsCache = derived.chartableSensors
                self.sensorsByCategoryCache = derived.sensorsByCategory
            } else {
                self.snapshot = nil
                self.lastUpdatedAt = Date()
                self.sensorHistory = [:]
                self.flattenedSensorsCache = []
                self.chartableSensorsCache = []
                self.sensorsByCategoryCache = []
            }
        } catch APIClientError.unauthorized {
            handleSessionExpired()
        } catch is CancellationError {
            // Polling cancellation during section switches is expected.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession cancellation should not surface as a user-facing error.
        } catch {
            errorMessage = error.localizedDescription
        }

        if showLoadingIndicator {
            isLoading = false
        }
    }

    // MARK: - 会话控制

    private func handleSessionExpired() {
        pollTask?.cancel()
        pollTask = nil
        telemetryPollingEnabled = false
        isDemoMode = false
        demoTick = 0
        session = nil
        snapshot = nil
        sensorHistory = [:]
        flattenedSensorsCache = []
        chartableSensorsCache = []
        sensorsByCategoryCache = []
        PersistedSession.wipe()
        errorMessage = "会话已过期，请重新扫码配对"
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        telemetryPollingEnabled = false
        isDemoMode = false
        demoTick = 0
        session = nil
        snapshot = nil
        status = nil
        sensorHistory = [:]
        flattenedSensorsCache = []
        chartableSensorsCache = []
        sensorsByCategoryCache = []
        lastUpdatedAt = nil
        PersistedSession.wipe()
    }

    // MARK: - 仪表盘支持

    func setTelemetryPollingEnabled(_ isEnabled: Bool) {
        let shouldEnable = isEnabled && isPaired
        if shouldEnable {
            if !telemetryPollingEnabled || pollTask == nil {
                telemetryPollingEnabled = true
                startPolling()
            }
            return
        }

        telemetryPollingEnabled = false
        guard isPaired else {
            pollTask?.cancel()
            pollTask = nil
            return
        }

        pollTask?.cancel()
        pollTask = nil
        if isLoading {
            isLoading = false
        }
    }

    func startReviewDemoMode() {
        pollTask?.cancel()
        pollTask = nil

        let expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        let endpoint = URL(string: "https://demo.preconnect.local/")!

        session = SessionInfo(
            token: "review-demo-\(UUID().uuidString)",
            expiresAt: expiresAt,
            serverName: "PreConnect演示主机",
            endpoint: endpoint,
            deviceId: localDeviceId,
            deviceName: localDeviceName
        )

        status = nil
        errorMessage = nil
        qrPhase = .idle
        isDemoMode = true
        telemetryPollingEnabled = true
        demoTick = 0

        startPolling()
        Task {
            await refreshTelemetryOnce(showLoadingIndicator: true)
        }
    }

    private func generateDemoSnapshot() -> HardwareSnapshot {
        demoTick += max(pollingInterval, 0.5)
        let t = demoTick

        func wave(_ base: Double, _ amplitude: Double, period: Double, phase: Double = 0) -> Double {
            base + amplitude * sin((t / period) + phase)
        }

        func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
            Swift.min(Swift.max(value, minValue), maxValue)
        }

        func sensor(
            _ id: String,
            _ name: String,
            _ type: Int,
            _ value: Double,
            min minValue: Double,
            max maxValue: Double,
            path: String,
            index: Int
        ) -> SensorReading {
            SensorReading(
                sensorId: id,
                sensorName: name,
                sensorType: type,
                value: value,
                min: minValue,
                max: maxValue,
                hardwarePath: path,
                index: index
            )
        }

        let cpuTemp = clamp(wave(62, 9, period: 7), min: 38, max: 95)
        let cpuLoad = clamp(wave(48, 28, period: 4, phase: 0.8), min: 8, max: 99)
        let cpuPackagePower = clamp(wave(70, 20, period: 6, phase: 0.2), min: 15, max: 145)
        let cpuClock = clamp(wave(3980, 520, period: 5, phase: 0.4), min: 2800, max: 5300)

        let gpuTemp = clamp(wave(58, 11, period: 8, phase: 0.6), min: 34, max: 92)
        let gpuLoad = clamp(wave(54, 35, period: 3.6, phase: 1.1), min: 5, max: 99)
        let gpuPower = clamp(wave(112, 35, period: 5.5, phase: 0.9), min: 35, max: 280)
        let gpuClock = clamp(wave(1800, 260, period: 4.5, phase: 0.5), min: 900, max: 2600)

        let memoryLoad = clamp(wave(63, 8, period: 10, phase: 0.3), min: 40, max: 88)
        let memoryUsedGb = clamp(wave(20, 3.2, period: 9, phase: 1.3), min: 12, max: 28)
        let fanRpm = clamp(wave(1450, 380, period: 6.2, phase: 0.75), min: 780, max: 2600)

        let diskTemp = clamp(wave(43, 5, period: 11, phase: 0.2), min: 30, max: 60)
        let diskLoad = clamp(wave(36, 30, period: 3.9, phase: 1.7), min: 1, max: 95)

        let cpu = HardwareComponent(
            hardwareId: "demo-cpu-0",
            hardwareName: "CPU Package",
            hardwareType: 2,
            manufacturer: "PreConnect Labs",
            sensors: [
                sensor("demo.cpu.temp", "CPU 温度", 4, cpuTemp, min: 0, max: 100, path: "CPU/Package", index: 0),
                sensor("demo.cpu.load", "CPU 占用", 5, cpuLoad, min: 0, max: 100, path: "CPU/Package", index: 1),
                sensor("demo.cpu.power", "CPU 功耗", 2, cpuPackagePower, min: 0, max: 200, path: "CPU/Package", index: 2),
                sensor("demo.cpu.clock", "CPU 频率", 14, cpuClock, min: 0, max: 6000, path: "CPU/Package", index: 3)
            ],
            children: [],
            properties: nil
        )

        let gpu = HardwareComponent(
            hardwareId: "demo-gpu-0",
            hardwareName: "GPU",
            hardwareType: 5,
            manufacturer: "PreConnect Labs",
            sensors: [
                sensor("demo.gpu.temp", "GPU 温度", 4, gpuTemp, min: 0, max: 100, path: "GPU", index: 0),
                sensor("demo.gpu.load", "GPU 占用", 5, gpuLoad, min: 0, max: 100, path: "GPU", index: 1),
                sensor("demo.gpu.power", "GPU 功耗", 2, gpuPower, min: 0, max: 350, path: "GPU", index: 2),
                sensor("demo.gpu.clock", "GPU 频率", 14, gpuClock, min: 0, max: 3000, path: "GPU", index: 3)
            ],
            children: [],
            properties: nil
        )

        let memory = HardwareComponent(
            hardwareId: "demo-memory-0",
            hardwareName: "内存",
            hardwareType: 3,
            manufacturer: "PreConnect Labs",
            sensors: [
                sensor("demo.mem.load", "内存占用", 5, memoryLoad, min: 0, max: 100, path: "Memory", index: 0),
                sensor("demo.mem.used", "内存已用", 3, memoryUsedGb, min: 0, max: 32, path: "Memory", index: 1)
            ],
            children: [],
            properties: nil
        )

        let cooling = HardwareComponent(
            hardwareId: "demo-fan-0",
            hardwareName: "散热系统",
            hardwareType: 7,
            manufacturer: "PreConnect Labs",
            sensors: [
                sensor("demo.fan.rpm", "风扇转速", 7, fanRpm, min: 0, max: 3200, path: "Cooling", index: 0)
            ],
            children: [],
            properties: nil
        )

        let storage = HardwareComponent(
            hardwareId: "demo-ssd-0",
            hardwareName: "固态硬盘",
            hardwareType: 4,
            manufacturer: "PreConnect Labs",
            sensors: [
                sensor("demo.disk.temp", "SSD 温度", 4, diskTemp, min: 0, max: 100, path: "Storage", index: 0),
                sensor("demo.disk.load", "磁盘占用", 5, diskLoad, min: 0, max: 100, path: "Storage", index: 1)
            ],
            children: [],
            properties: nil
        )

        return HardwareSnapshot(components: [cpu, gpu, memory, cooling, storage])
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
            .sorted { lhs, rhs in Self.chartPriority(for: lhs) > Self.chartPriority(for: rhs) }
            .prefix(limit)
            .map(\.id)
    }

    func defaultWidgetConfigs(limit: Int = 6) -> [DashboardWidgetConfig] {
        availableSensors
            .sorted { lhs, rhs in Self.chartPriority(for: lhs) > Self.chartPriority(for: rhs) }
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

    // MARK: - 轮询控制

    private func startPolling() {
        telemetryPollingEnabled = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTelemetryOnce(showLoadingIndicator: false)
                
                let interval = self?.pollingInterval ?? Self.defaultPollingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - 辅助方法

    private func normalizedBaseURL() throws -> URL {
        var text = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text) else { throw APIClientError.invalidBaseURL }
        return url
    }

    private nonisolated static func deriveTelemetryData(snapshot: HardwareSnapshot, existingHistory: [String: [MetricSample]]) -> TelemetryDerivedData {
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

        var nextHistory = existingHistory
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

        let filteredHistory = nextHistory.filter { activeSensorIDs.contains($0.key) }
        let chartableSensors = sensors
            .sorted { lhs, rhs in
                if (lhs.value != nil) != (rhs.value != nil) {
                    return lhs.value != nil
                }
                if lhs.componentName != rhs.componentName {
                    return lhs.componentName < rhs.componentName
                }
                return lhs.sensorName < rhs.sensorName
            }
        let sensorsByCategory = SensorCategory.allCases.compactMap { category in
            let grouped = chartableSensors.filter { $0.category == category }
            return grouped.isEmpty ? nil : (category: category, sensors: grouped)
        }

        return TelemetryDerivedData(
            flattenedSensors: sensors,
            chartableSensors: chartableSensors,
            sensorsByCategory: sensorsByCategory,
            history: filteredHistory,
            updatedAt: now
        )
    }

    private nonisolated static func chartPriority(for item: SensorDisplayItem) -> Int {
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
