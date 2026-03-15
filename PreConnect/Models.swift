import Foundation
import SwiftUI

struct PingResponse: Decodable {
    let ok: Bool
    let name: String?
    let time: String?
}

struct StatusResponse: Decodable {
    let name: String?
    let isRunning: Bool?
    let endpoint: String
    let activeConnections: Int?
    let lastRequestUtc: String?
    let machineName: String?
    let os: String?
    let version: String?
}

struct PairRequest: Encodable {
    let pin: String
    let deviceId: String
    let name: String
    let rotatingKey: String?

    init(pin: String, deviceId: String, name: String, rotatingKey: String? = nil) {
        self.pin = pin
        self.deviceId = deviceId
        self.name = name
        self.rotatingKey = rotatingKey
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pin,      forKey: .pin)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(name,     forKey: .name)
        try c.encodeIfPresent(rotatingKey, forKey: .rotatingKey)
    }

    enum CodingKeys: String, CodingKey { case pin, deviceId, name, rotatingKey }
}

struct PairResponse: Decodable {
    let ok: Bool
    let sessionToken: String
    let sessionTokenExpiresUtc: String?
    let serverName: String
    let endpoint: String
    let deviceId: String
    let deviceName: String
}

struct TelemetryResponse: Decodable {
    let ok: Bool
    let deviceId: String?
    let deviceName: String?
    let expiresAtUtc: String?
    let snapshot: HardwareSnapshot?
}

struct HardwareSnapshot: Decodable {
    let components: [HardwareComponent]
}

struct HardwareComponent: Decodable {
    let hardwareId: String
    let hardwareName: String
    let hardwareType: Int
    let manufacturer: String?
    let sensors: [SensorReading]
    let children: [HardwareComponent]
    let properties: [String: String]?

    var allComponents: [HardwareComponent] {
        [self] + children.flatMap(\.allComponents)
    }
}

struct SensorReading: Decodable {
    let sensorId: String
    let sensorName: String
    let sensorType: Int
    let value: Double?
    let min: Double?
    let max: Double?
    let hardwarePath: String?
    let index: Int?
}

struct SessionInfo {
    let token: String
    let expiresAt: Date?
    let serverName: String
    let endpoint: URL
    let deviceId: String
    let deviceName: String
}

struct MetricSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct SensorChartState: Identifiable {
    let sensorId: String
    let sensorName: String
    let componentName: String
    let sensorType: Int
    let currentValue: Double?
    let samples: [MetricSample]

    var id: String { sensorId }

    var accentColor: Color {
        sensorColor(for: sensorType, value: currentValue)
    }

    var symbolName: String {
        switch sensorType {
        case 2: return "bolt.fill"
        case 4: return "thermometer.medium"
        case 5: return "chart.line.uptrend.xyaxis"
        case 7: return "fan.fill"
        case 14: return "gauge.with.needle.fill"
        default: return "waveform.path.ecg"
        }
    }

    var currentValueText: String {
        SensorDisplayItem.formatValue(sensorType: sensorType, value: currentValue)
    }

    var yAxisLabel: String {
        switch sensorType {
        case 2: return "W"
        case 4: return "C"
        case 5: return "%"
        case 7: return "RPM"
        case 14: return "MHz"
        default: return "值"
        }
    }

    private func sensorColor(for sensorType: Int, value: Double?) -> Color {
        guard let value else { return .gray }
        switch sensorType {
        case 4:
            if value >= 90 { return .red }
            if value >= 70 { return .orange }
            return .green
        case 5:
            if value >= 90 { return .red }
            if value >= 70 { return .orange }
            return .blue
        case 2:
            return .yellow
        case 7:
            return .teal
        default:
            return .indigo
        }
    }
}

enum DashboardWidgetDisplayMode: String, CaseIterable, Codable, Identifiable {
    case chart
    case value
    case progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chart: return "图表"
        case .value: return "数字"
        case .progress: return "数字 + 进度条"
        }
    }

    var symbolName: String {
        switch self {
        case .chart: return "chart.xyaxis.line"
        case .value: return "number.square.fill"
        case .progress: return "gauge.with.needle.fill"
        }
    }

    func gridSpan(for tier: DashboardScaleTier) -> DashboardGridSpan {
        switch self {
        case .chart:
            switch tier {
            case .normal:
                return DashboardGridSpan(columns: 6, rows: 3)
            case .compact:
                return DashboardGridSpan(columns: 4, rows: 3)
            }
        case .value:
            return DashboardGridSpan(columns: 3, rows: 2)
        case .progress:
            return DashboardGridSpan(columns: 3, rows: 2)
        }
    }
}

enum DashboardScaleTier: String, Codable {
    case normal
    case compact

    var title: String {
        switch self {
        case .normal: return "标准"
        case .compact: return "紧凑"
        }
    }
}

struct DashboardWidgetConfig: Codable, Hashable, Identifiable {
    let sensorId: String
    var displayMode: DashboardWidgetDisplayMode

    var id: String { sensorId }
}

struct DashboardWidgetState: Identifiable {
    let config: DashboardWidgetConfig
    let sensor: SensorDisplayItem
    let samples: [MetricSample]

    var id: String { config.id }
}

struct DashboardGridSpan: Hashable {
    let columns: Int
    let rows: Int
}

struct DashboardLayoutPlacement: Identifiable {
    let widgetID: String
    let column: Int
    let row: Int
    let span: DashboardGridSpan

    var id: String { widgetID }
}

struct DashboardLayoutResult {
    let placements: [DashboardLayoutPlacement]
    let canFitAll: Bool
    let scaleTier: DashboardScaleTier
}

enum DashboardLayoutEngine {
    static let gridColumns = 14
    static let gridRows = 7

    static func layout(for widgets: [DashboardWidgetConfig]) -> DashboardLayoutResult {
        for tier in [DashboardScaleTier.normal, DashboardScaleTier.compact] {
            let attempt = layout(for: widgets, scaleTier: tier)
            if attempt.canFitAll {
                return attempt
            }
        }

        return layout(for: widgets, scaleTier: .compact)
    }

    private static func layout(for widgets: [DashboardWidgetConfig], scaleTier: DashboardScaleTier) -> DashboardLayoutResult {
        var occupied = Array(
            repeating: Array(repeating: false, count: gridColumns),
            count: gridRows
        )
        var placements: [DashboardLayoutPlacement] = []

        let orderedWidgets = widgets.sorted {
            let lhsSpan = $0.displayMode.gridSpan(for: scaleTier)
            let rhsSpan = $1.displayMode.gridSpan(for: scaleTier)
            let lhsArea = lhsSpan.columns * lhsSpan.rows
            let rhsArea = rhsSpan.columns * rhsSpan.rows
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return $0.sensorId < $1.sensorId
        }

        for widget in orderedWidgets {
            let span = widget.displayMode.gridSpan(for: scaleTier)
            var placed = false

            for row in 0...(gridRows - span.rows) {
                for column in 0...(gridColumns - span.columns) {
                    if canPlace(span: span, atColumn: column, row: row, occupied: occupied) {
                        mark(span: span, atColumn: column, row: row, occupied: &occupied)
                        placements.append(
                            DashboardLayoutPlacement(
                                widgetID: widget.id,
                                column: column,
                                row: row,
                                span: span
                            )
                        )
                        placed = true
                        break
                    }
                }

                if placed { break }
            }

            if !placed {
                return DashboardLayoutResult(placements: placements, canFitAll: false, scaleTier: scaleTier)
            }
        }

        return DashboardLayoutResult(placements: placements, canFitAll: true, scaleTier: scaleTier)
    }

    static func canFit(_ widgets: [DashboardWidgetConfig]) -> Bool {
        layout(for: widgets).canFitAll
    }

    private static func canPlace(span: DashboardGridSpan, atColumn column: Int, row: Int, occupied: [[Bool]]) -> Bool {
        for rowIndex in row..<(row + span.rows) {
            for columnIndex in column..<(column + span.columns) {
                if occupied[rowIndex][columnIndex] {
                    return false
                }
            }
        }
        return true
    }

    private static func mark(span: DashboardGridSpan, atColumn column: Int, row: Int, occupied: inout [[Bool]]) {
        for rowIndex in row..<(row + span.rows) {
            for columnIndex in column..<(column + span.columns) {
                occupied[rowIndex][columnIndex] = true
            }
        }
    }
}

enum SensorCategory: String, CaseIterable, Identifiable {
    case temperature
    case power
    case fan
    case clock
    case load
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "温度"
        case .power: return "功耗"
        case .fan: return "风扇"
        case .clock: return "频率"
        case .load: return "负载"
        case .raw: return "其他"
        }
    }
}

enum SensorSection: String, CaseIterable, Identifiable {
    case temperature
    case power
    case fan
    case clock
    case load

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "温度"
        case .power: return "功耗"
        case .fan: return "风扇"
        case .clock: return "频率"
        case .load: return "其他负载"
        }
    }

    var symbolName: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .power: return "bolt.fill"
        case .fan: return "fan.fill"
        case .clock: return "gauge.with.needle.fill"
        case .load: return "chart.bar.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .temperature: return .red
        case .power: return .yellow
        case .fan: return .teal
        case .clock: return .indigo
        case .load: return .blue
        }
    }
}

struct DashboardFact: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbolName: String
}

struct SensorDisplayItem: Identifiable {
    let id: String
    let componentName: String
    let sensorName: String
    let sensorType: Int
    let value: Double?
    let min: Double?
    let max: Double?
    let hardwarePath: String?

    var sensorTypeLabel: String {
        switch sensorType {
        case 2: return "Power"
        case 3: return "Clock"
        case 4: return "Temp"
        case 5: return "Load"
        case 7: return "Fan"
        case 14: return "Clock"
        default: return "Raw"
        }
    }

    var valueText: String {
        Self.formatValue(sensorType: sensorType, value: value)
    }

    static func formatValue(sensorType: Int, value: Double?) -> String {
        guard let value else { return "N/A" }
        switch sensorType {
        case 2: return String(format: "%.1f W", value)
        case 3: return String(format: "%.0f MHz", value)
        case 4: return String(format: "%.1f C", value)
        case 5: return String(format: "%.0f %%", value)
        case 7: return String(format: "%.0f RPM", value)
        case 14: return String(format: "%.0f MHz", value)
        default: return String(format: "%.2f", value)
        }
    }

    var valueSummaryText: String {
        let minText = min.map { String(format: "%.1f", $0) } ?? "--"
        let maxText = max.map { String(format: "%.1f", $0) } ?? "--"
        return "Min \(minText) / Max \(maxText)"
    }

    var progressFraction: Double? {
        guard let value else { return nil }
        switch sensorType {
        case 4: return Swift.min(Swift.max(value / 100.0, 0), 1)
        case 5: return Swift.min(Swift.max(value / 100.0, 0), 1)
        default: return nil
        }
    }

    var color: Color {
        guard let value else { return .gray }
        switch sensorType {
        case 4:
            if value >= 90 { return .red }
            if value >= 70 { return .orange }
            return .green
        case 5:
            if value >= 90 { return .red }
            if value >= 70 { return .orange }
            return .blue
        case 2:
            return .yellow
        case 7:
            return .teal
        case 3, 14:
            return .indigo
        default:
            return .indigo
        }
    }

    var section: SensorSection? {
        switch sensorType {
        case 2: return .power
        case 3: return .clock
        case 4: return .temperature
        case 5: return .load
        case 7: return .fan
        case 14: return .clock
        default: return nil
        }
    }

    var searchText: String {
        [componentName, sensorName, hardwarePath ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    var category: SensorCategory {
        switch sensorType {
        case 2: return .power
        case 3: return .clock
        case 4: return .temperature
        case 5: return .load
        case 7: return .fan
        case 14: return .clock
        default: return .raw
        }
    }

    var supportedDisplayModes: [DashboardWidgetDisplayMode] {
        switch sensorType {
        case 4, 5:
            return [.chart, .value, .progress]
        case 2, 3, 7, 14:
            return [.chart, .value]
        default:
            return [.chart, .value]
        }
    }

    var chartDisplayName: String {
        sensorName
    }

    var chartSubtitle: String {
        componentName
    }
}
