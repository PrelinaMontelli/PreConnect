import SwiftUI
import Charts
import Combine

private enum AppSection: Hashable {
    case setup
    case dashboard
    case settings
}

private enum DashboardPreferenceKey {
    static let widgetConfigurations = "dashboard.widgetConfigurations"
    static let pollingInterval = "dashboard.pollingInterval"
}

private enum WidgetConfigurationStore {
    static func decode(_ rawValue: String) -> [DashboardWidgetConfig] {
        guard let data = rawValue.data(using: .utf8),
              let configs = try? JSONDecoder().decode([DashboardWidgetConfig].self, from: data) else {
            return []
        }
        return configs
    }

    static func encode(_ configs: [DashboardWidgetConfig]) -> String {
        guard let data = try? JSONEncoder().encode(configs),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showScanner = false
    @State private var selectedSection: AppSection? = .setup
    @AppStorage(DashboardPreferenceKey.pollingInterval) private var pollingInterval = AppViewModel.defaultPollingInterval

    private var showError: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { newValue in
                if !newValue { vm.errorMessage = nil }
            }
        )
    }

    private var activeSection: AppSection {
        selectedSection ?? (vm.isPaired ? .dashboard : .setup)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedSection: $selectedSection, vm: vm)
        } detail: {
            ZStack {
                AppBackground()
                detailContent
            }
            .toolbar {
                if activeSection == .dashboard && vm.isPaired {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if vm.isLoading {
                            ProgressView()
                        }

                        Button {
                            Task { await vm.refreshTelemetryOnce() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .alert("错误", isPresented: showError) {
            Button("确定") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $showScanner, onDismiss: { vm.cancelQRScan() }) {
            QRScanSheet(vm: vm)
        }
        .onAppear {
            vm.updatePollingInterval(pollingInterval)
            if vm.isPaired {
                selectedSection = .dashboard
            }
        }
        .onChange(of: pollingInterval) { _, newValue in
            vm.updatePollingInterval(newValue)
        }
        .onChange(of: vm.isPaired) { _, isPaired in
            if isPaired {
                selectedSection = .dashboard
            } else if selectedSection == .dashboard {
                selectedSection = .setup
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch activeSection {
        case .setup:
            SetupWorkspaceView(vm: vm, showScanner: $showScanner)
        case .dashboard:
            if vm.isPaired {
                DashboardView(vm: vm)
            } else {
                DashboardLockedView(selectedSection: $selectedSection)
            }
        case .settings:
            SettingsView(vm: vm)
        }
    }
}

private struct SidebarView: View {
    @Binding var selectedSection: AppSection?
    @ObservedObject var vm: AppViewModel

    var body: some View {
        List(selection: $selectedSection) {
            Section("工作区") {
                Label("连接与配对", systemImage: "dot.radiowaves.left.and.right")
                    .tag(AppSection.setup)
                Label("监控面板", systemImage: "waveform.path.ecg.rectangle")
                    .tag(AppSection.dashboard)
                Label("显示设置", systemImage: "slider.horizontal.3")
                    .tag(AppSection.settings)
            }

            Section("当前状态") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vm.isPaired ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text(vm.isPaired ? "已配对" : "未配对")
                            .font(.headline)
                    }

                    if let session = vm.session {
                        Text(session.serverName)
                            .font(.subheadline.weight(.medium))
                        Text(session.endpoint.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("完成配对后，这里会显示当前连接主机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("PreConnect")
    }
}

private struct SetupWorkspaceView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var showScanner: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SetupHeroCard(vm: vm)

                    LazyVGrid(columns: setupColumns(for: geometry.size.width), spacing: 20) {
                        ConnectionCard(vm: vm)
                        PairingCard(vm: vm, showScanner: $showScanner)
                        SetupStatusCard(vm: vm)
                    }
                }
                .frame(maxWidth: 1320)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    private func setupColumns(for width: CGFloat) -> [GridItem] {
        width >= 1100
            ? [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]
            : [GridItem(.flexible(), spacing: 20)]
    }
}

private struct SetupHeroCard: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("iPad 监控工作台")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("完成配对后，监控页可以为任意传感器绘制历史曲线，并将其他硬件信息按温度、功耗、风扇和频率分区展示。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 8) {
                    Label(vm.isPaired ? "在线监控中" : "等待配对", systemImage: vm.isPaired ? "checkmark.seal.fill" : "bolt.badge.clock")
                        .font(.headline)
                        .foregroundStyle(vm.isPaired ? .green : .orange)
                    if let updatedAt = vm.lastUpdatedAt {
                        Text("最近更新 \(updatedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 14) {
                SetupStatPill(title: "图表监控", value: "任意传感器", tint: .blue)
                SetupStatPill(title: "可控区块", value: "8 项", tint: .orange)
                SetupStatPill(title: "轮询频率", value: vm.pollingIntervalText, tint: .green)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.32), Color(red: 0.11, green: 0.43, blue: 0.58)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 180, height: 180)
                .offset(x: 50, y: -60)
        }
        .foregroundStyle(.white)
    }
}

private struct SetupStatPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.headline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ConnectionCard: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "服务连接", subtitle: "先验证 API 端点，再进行配对", symbolName: "network")

                TextField("服务根地址，例如 http://192.168.1.12:5005/", text: $vm.baseURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.body.monospaced())
                    .padding(14)
                    .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 12) {
                    Button {
                        Task { await vm.pingAndLoadStatus() }
                    } label: {
                        Label("验证服务", systemImage: "bolt.horizontal.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.isLoading)

                    if let endpoint = vm.status?.endpoint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vm.status?.machineName ?? URL(string: endpoint)?.host ?? "主机")
                                .font(.headline)
                            Text(endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct PairingCard: View {
    @ObservedObject var vm: AppViewModel
    @Binding var showScanner: Bool

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "设备配对", subtitle: "扫码优先，手动 PIN 作为兜底", symbolName: "qrcode.viewfinder")

                Button {
                    vm.startQRScanning()
                    showScanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text(vm.isPaired ? "重新扫码配对" : "扫码配对")
                        Spacer()
                        Image(systemName: "arrow.up.right.and.arrow.down.left.rectangle")
                    }
                    .font(.headline)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 10) {
                    Capsule().fill(.quaternary).frame(height: 1)
                    Text("或输入主机上的 6 位 PIN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Capsule().fill(.quaternary).frame(height: 1)
                }

                TextField("6 位 PIN", text: $vm.pin)
                    .keyboardType(.numberPad)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onChange(of: vm.pin) { _, newValue in
                        vm.pin = String(newValue.filter(\.isNumber).prefix(6))
                    }

                HStack(spacing: 12) {
                    Button {
                        Task { await vm.pair() }
                    } label: {
                        Label("开始配对", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.pin.count != 6 || vm.isLoading)

                    if let session = vm.session {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已连接到 \(session.serverName)")
                                .font(.headline)
                            if let expire = session.expiresAt {
                                Text("会话到期 \(expire.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct SetupStatusCard: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "当前会话", subtitle: "监控页会在配对成功后自动激活", symbolName: "waveform.path.ecg.rectangle")

                if let session = vm.session {
                    VStack(alignment: .leading, spacing: 14) {
                        StatusFactRow(title: "主机", value: session.serverName, symbolName: "desktopcomputer")
                        StatusFactRow(title: "客户端设备", value: session.deviceName, symbolName: "ipad.and.iphone")
                        StatusFactRow(title: "端点", value: session.endpoint.absoluteString, symbolName: "network")
                        if let expiresAt = session.expiresAt {
                            StatusFactRow(
                                title: "会话有效期",
                                value: expiresAt.formatted(date: .numeric, time: .shortened),
                                symbolName: "clock.badge.checkmark"
                            )
                        }
                    }
                } else {
                    Text("当前还没有活跃会话。完成二维码或 PIN 配对后，监控面板会显示实时图表和硬件详情。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var vm: AppViewModel
    @AppStorage(DashboardPreferenceKey.widgetConfigurations) private var widgetConfigurationsRaw = "[]"

    private var widgetConfigurations: [DashboardWidgetConfig] {
        WidgetConfigurationStore.decode(widgetConfigurationsRaw)
    }

    private var widgetStates: [DashboardWidgetState] {
        vm.widgetStates(for: widgetConfigurations)
    }

    private var layoutResult: DashboardLayoutResult {
        DashboardLayoutEngine.layout(for: widgetConfigurations)
    }

    var body: some View {
        Group {
            if vm.snapshot == nil {
                DashboardLoadingPlaceholder()
            } else if widgetStates.isEmpty {
                DashboardEmptyCustomizationView()
            } else if !layoutResult.canFitAll {
                DashboardCapacityWarningView()
            } else {
                DashboardCanvasView(layoutResult: layoutResult, widgetStates: widgetStates)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureDefaultWidgetsIfNeeded()
        }
        .onChange(of: vm.chartableSensors.map(\.id)) { _, _ in
            ensureDefaultWidgetsIfNeeded()
        }
    }

    private func ensureDefaultWidgetsIfNeeded() {
        guard widgetConfigurations.isEmpty else { return }
        let defaults = vm.defaultWidgetConfigs()
        guard !defaults.isEmpty else { return }
        widgetConfigurationsRaw = WidgetConfigurationStore.encode(defaults)
    }
}

private struct DashboardCanvasView: View {
    let layoutResult: DashboardLayoutResult
    let widgetStates: [DashboardWidgetState]

    private let canvasPadding: CGFloat = 10
    private let cellSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(geometry.size.width - canvasPadding * 2, 0)
            let usableHeight = max(geometry.size.height - canvasPadding * 2, 0)
            let rawCellWidth = (usableWidth - cellSpacing * CGFloat(DashboardLayoutEngine.gridColumns - 1)) / CGFloat(DashboardLayoutEngine.gridColumns)
            let rawCellHeight = (usableHeight - cellSpacing * CGFloat(DashboardLayoutEngine.gridRows - 1)) / CGFloat(DashboardLayoutEngine.gridRows)
            let cellWidth = max(rawCellWidth, 20)
            let cellHeight = max(rawCellHeight, 20)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.52))

                ForEach(layoutResult.placements) { placement in
                    if let widget = widgetStates.first(where: { $0.id == placement.widgetID }) {
                        DashboardWidgetTile(widget: widget)
                            .frame(
                                width: CGFloat(placement.span.columns) * cellWidth + CGFloat(placement.span.columns - 1) * cellSpacing,
                                height: CGFloat(placement.span.rows) * cellHeight + CGFloat(placement.span.rows - 1) * cellSpacing
                            )
                            .position(
                                x: canvasPadding + CGFloat(placement.column) * (cellWidth + cellSpacing) + (CGFloat(placement.span.columns) * cellWidth + CGFloat(placement.span.columns - 1) * cellSpacing) / 2,
                                y: canvasPadding + CGFloat(placement.row) * (cellHeight + cellSpacing) + (CGFloat(placement.span.rows) * cellHeight + CGFloat(placement.span.rows - 1) * cellSpacing) / 2
                            )
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        Text("布局：\(layoutResult.scaleTier.title)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.9), in: Capsule())
                    }
                    Spacer()
                }
                .padding(10)

                if rawCellWidth < 20 || rawCellHeight < 20 {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("可用空间不足，部分组件可能重叠")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct DashboardWidgetTile: View {
    let widget: DashboardWidgetState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(widget.sensor.sensorName, systemImage: widgetIcon)
                        .font(.headline)
                    Text(widget.sensor.componentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            switch widget.config.displayMode {
            case .chart:
                SensorWidgetChart(samples: widget.samples, sensor: widget.sensor)
            case .value:
                ValueWidgetContent(sensor: widget.sensor)
            case .progress:
                ProgressWidgetContent(sensor: widget.sensor)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var widgetIcon: String {
        switch widget.config.displayMode {
        case .chart: return "chart.xyaxis.line"
        case .value: return "number.square.fill"
        case .progress: return "gauge.with.needle.fill"
        }
    }
}

private struct SensorWidgetChart: View {
    let samples: [MetricSample]
    let sensor: SensorDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sensor.valueText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(sensor.color)

            if samples.isEmpty {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay { Text("等待数据").foregroundStyle(.secondary) }
            } else {
                Chart(samples) { sample in
                    AreaMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                        .foregroundStyle(sensor.color.opacity(0.14))
                    LineMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(sensor.color)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ValueWidgetContent: View {
    let sensor: SensorDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(sensor.valueText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(sensor.color)
            Text(sensor.valueSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct ProgressWidgetContent: View {
    let sensor: SensorDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Text(sensor.valueText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(sensor.color)

            ProgressView(value: sensor.progressFraction ?? inferredFraction)
                .tint(sensor.color)

            Text(sensor.valueSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var inferredFraction: Double {
        guard let value = sensor.value else { return 0 }
        return Swift.min(Swift.max(value / 100.0, 0), 1)
    }
}

private struct DashboardCapacityWarningView: View {
    var body: some View {
        DashboardSurfaceCard {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("当前布局超出单屏容量")
                    .font(.title3.bold())
                Text("请回到显示设置减少组件，或把部分项目切换为更小的数字组件。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct InfoBadge: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SensorChartCard: View {
    let chart: SensorChartState

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(chart.sensorName, systemImage: chart.symbolName)
                            .font(.headline)
                        Text(chart.componentName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(chart.currentValueText)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(chart.accentColor)
                    }
                    Spacer()
                    CircularMetricView(value: chart.currentValue ?? 0, color: chart.accentColor)
                }

                if chart.samples.isEmpty {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 180)
                        .overlay {
                            Text("等待遥测数据")
                                .foregroundStyle(.secondary)
                        }
                } else {
                    Chart(chart.samples) { sample in
                        AreaMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("占用", sample.value)
                        )
                        .foregroundStyle(chart.accentColor.opacity(0.16))

                        LineMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("占用", sample.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(chart.accentColor)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 190)
                }
            }
        }
    }
}

private struct CircularMetricView: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: Swift.min(Swift.max(value / 100, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(String(format: "%.0f%%", value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: 74, height: 74)
    }
}

private struct OverviewGridCard: View {
    let facts: [DashboardFact]

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "系统概览", subtitle: "图文卡片汇总会话与主机状态", symbolName: "rectangle.grid.2x2.fill")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: fact.symbolName)
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Text(fact.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(fact.value)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                        .padding(16)
                        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct SensorSectionCard: View {
    let section: SensorSection
    let items: [SensorDisplayItem]

    var body: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: section.title, subtitle: "显示当前最关键的 \(min(items.count, 8)) 项传感器数据", symbolName: section.symbolName)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(Array(items.prefix(8))) { item in
                        SensorRow(item: item, accentColor: section.accentColor)
                    }
                }
            }
        }
    }
}

private struct SensorRow: View {
    let item: SensorDisplayItem
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.sensorName)
                        .font(.headline)
                    Text(item.componentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(item.sensorTypeLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accentColor.opacity(0.16), in: Capsule())
            }

            Text(item.valueText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accentColor)

            if let fraction = item.progressFraction {
                ProgressView(value: fraction)
                    .tint(accentColor)
            }

            Text(item.valueSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DashboardLockedView: View {
    @Binding var selectedSection: AppSection?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.rectangle.stack.fill")
                .font(.system(size: 54))
                .foregroundStyle(.orange)
            Text("监控面板尚未解锁")
                .font(.title.bold())
            Text("请先到“连接与配对”完成主机认证，固定仪表盘才会开始拉取并展示硬件数据。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("前往连接与配对") {
                selectedSection = .setup
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct DashboardLoadingPlaceholder: View {
    var body: some View {
        DashboardSurfaceCard {
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.3)
                Text("正在等待第一帧遥测数据")
                    .font(.headline)
                Text("配对已经完成，应用会继续轮询远端 API。一旦收到数据，图表和信息卡片会自动填充。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }
}

private struct DashboardEmptyCustomizationView: View {
    var body: some View {
        DashboardSurfaceCard {
            VStack(spacing: 14) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)
                Text("当前没有仪表盘组件")
                    .font(.title3.bold())
                Text("请到显示设置里为传感器选择展示模式。添加成功后，组件会自动排布到这块固定画布里。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var vm: AppViewModel
    @AppStorage(DashboardPreferenceKey.widgetConfigurations) private var widgetConfigurationsRaw = "[]"
    @AppStorage(DashboardPreferenceKey.pollingInterval) private var pollingInterval = AppViewModel.defaultPollingInterval
    @State private var warningMessage: String?

    private var widgetConfigurations: [DashboardWidgetConfig] {
        WidgetConfigurationStore.decode(widgetConfigurationsRaw)
    }

    private var layoutResult: DashboardLayoutResult {
        DashboardLayoutEngine.layout(for: widgetConfigurations)
    }

    private var usedGridCells: Int {
        layoutResult.placements.reduce(0) { partial, placement in
            partial + placement.span.columns * placement.span.rows
        }
    }

    private var totalGridCells: Int {
        DashboardLayoutEngine.gridColumns * DashboardLayoutEngine.gridRows
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width >= 1200 {
                    HStack(alignment: .top, spacing: 20) {
                        sensorConfigurationPanel
                            .frame(maxWidth: .infinity)

                        VStack(spacing: 20) {
                            dashboardStatusPanel
                            pollingPanel
                            connectionPanel
                        }
                        .frame(width: 360)
                    }
                    .frame(maxWidth: 1320)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        sensorConfigurationPanel
                        dashboardStatusPanel
                        pollingPanel
                        connectionPanel
                    }
                    .frame(maxWidth: 1100)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("显示设置")
        .alert("无法添加组件", isPresented: warningBinding) {
            Button("确定") { warningMessage = nil }
        } message: {
            Text(warningMessage ?? "")
        }
        .onAppear {
            vm.updatePollingInterval(pollingInterval)
            if widgetConfigurations.isEmpty {
                let defaults = vm.defaultWidgetConfigs()
                if !defaults.isEmpty {
                    widgetConfigurationsRaw = WidgetConfigurationStore.encode(defaults)
                }
            }
        }
        .onChange(of: pollingInterval) { _, newValue in
            vm.updatePollingInterval(newValue)
        }
    }

    private var sensorConfigurationPanel: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "仪表盘组件", subtitle: "为每个传感器选择合适的展示模式", symbolName: "square.grid.3x3.topleft.filled")

                if vm.sensorsByCategory.isEmpty {
                    Text("等待遥测数据后才能配置仪表盘组件。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.sensorsByCategory, id: \.category.id) { group in
                        SensorCategorySection(
                            title: group.category.title,
                            sensors: group.sensors,
                            selectedMode: selectedMode,
                            canSelectMode: canSelect,
                            onSelect: setMode,
                            onRemove: removeWidget
                        )
                    }
                }
            }
        }
    }

    private var pollingPanel: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "轮询速率", subtitle: "修改后台请求数据的频率", symbolName: "timer")
                PollingIntervalPicker(selectedInterval: $pollingInterval)
            }
        }
    }

    private var dashboardStatusPanel: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "监控展示设置", subtitle: "当前仪表盘容量和布局状态", symbolName: "slider.horizontal.3")
                StatusFactRow(title: "当前组件数", value: "\(widgetConfigurations.count)", symbolName: "square.grid.3x2")
                StatusFactRow(title: "布局状态", value: layoutResult.canFitAll ? "可完整显示" : "容量不足", symbolName: "aspectratio.fill")
                StatusFactRow(title: "自动缩放", value: layoutResult.scaleTier.title, symbolName: "arrow.up.left.and.arrow.down.right")

                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(usedGridCells), total: Double(totalGridCells))
                        .tint(layoutResult.canFitAll ? .blue : .orange)
                    Text("画布占用 \(usedGridCells) / \(totalGridCells) 单元")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectionPanel: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "连接控制", subtitle: "管理当前配对会话", symbolName: "lock.shield.fill")

                if let session = vm.session {
                    StatusFactRow(title: "当前主机", value: session.serverName, symbolName: "desktopcomputer")
                    StatusFactRow(title: "远端地址", value: session.endpoint.absoluteString, symbolName: "network")
                    if let expiresAt = session.expiresAt {
                        StatusFactRow(title: "会话到期", value: expiresAt.formatted(date: .numeric, time: .shortened), symbolName: "clock.fill")
                    }

                    Button(role: .destructive) {
                        vm.disconnect()
                    } label: {
                        Label("断开当前会话", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("当前没有活跃连接。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var warningBinding: Binding<Bool> {
        Binding(
            get: { warningMessage != nil },
            set: { newValue in
                if !newValue { warningMessage = nil }
            }
        )
    }

    private func selectedMode(for sensorID: String) -> DashboardWidgetDisplayMode? {
        widgetConfigurations.first(where: { $0.sensorId == sensorID })?.displayMode
    }

    private func setMode(_ mode: DashboardWidgetDisplayMode, for sensor: SensorDisplayItem) {
        guard sensor.supportedDisplayModes.contains(mode) else { return }

        var next = widgetConfigurations
        if let index = next.firstIndex(where: { $0.sensorId == sensor.id }) {
            next[index].displayMode = mode
        } else {
            next.append(DashboardWidgetConfig(sensorId: sensor.id, displayMode: mode))
        }

        guard vm.canFitWidgets(next) else {
            warningMessage = "当前组件在自动缩放后仍无法容纳该组件。请先移除部分组件，或改用更紧凑的数字显示。"
            return
        }

        widgetConfigurationsRaw = WidgetConfigurationStore.encode(next)
    }

    private func removeWidget(for sensorID: String) {
        let next = widgetConfigurations.filter { $0.sensorId != sensorID }
        widgetConfigurationsRaw = WidgetConfigurationStore.encode(next)
    }

    private func canSelect(_ mode: DashboardWidgetDisplayMode, for sensor: SensorDisplayItem) -> Bool {
        guard sensor.supportedDisplayModes.contains(mode) else { return false }

        var next = widgetConfigurations
        if let index = next.firstIndex(where: { $0.sensorId == sensor.id }) {
            next[index].displayMode = mode
        } else {
            next.append(DashboardWidgetConfig(sensorId: sensor.id, displayMode: mode))
        }

        return vm.canFitWidgets(next)
    }
}

private struct SensorCategorySection: View {
    let title: String
    let sensors: [SensorDisplayItem]
    let selectedMode: (String) -> DashboardWidgetDisplayMode?
    let canSelectMode: (DashboardWidgetDisplayMode, SensorDisplayItem) -> Bool
    let onSelect: (DashboardWidgetDisplayMode, SensorDisplayItem) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(sensors) { sensor in
                    SensorConfiguratorCard(
                        sensor: sensor,
                        selectedMode: selectedMode(sensor.id),
                        canSelectMode: { mode in canSelectMode(mode, sensor) },
                        onSelect: { mode in onSelect(mode, sensor) },
                        onRemove: { onRemove(sensor.id) }
                    )
                }
            }
        }
    }
}

private struct PollingIntervalPicker: View {
    @Binding var selectedInterval: TimeInterval

    private let options: [TimeInterval] = [0.5, 1, 2, 3, 5, 10]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前频率：\(label(for: selectedInterval))")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(options, id: \.self) { option in
                    optionButton(for: option)
                }
            }

            Text("更短的间隔会让图表更实时，但可能也会增加对远端设备和网络的请求压力。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func optionButton(for option: TimeInterval) -> some View {
        let isSelected = selectedInterval == option

        return Button {
            selectedInterval = option
        } label: {
            Text(label(for: option))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(
            (isSelected ? Color.blue.opacity(0.14) : Color.white.opacity(0.80)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
    }

    private func label(for value: TimeInterval) -> String {
        if value < 1 {
            return String(format: "%.1f 秒", value)
        }
        return String(format: "%.0f 秒", value)
    }
}

private struct SensorConfiguratorCard: View {
    let sensor: SensorDisplayItem
    let selectedMode: DashboardWidgetDisplayMode?
    let canSelectMode: (DashboardWidgetDisplayMode) -> Bool
    let onSelect: (DashboardWidgetDisplayMode) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            valueLine
            modeGrid
            if selectedMode != nil { removeButton }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sensor.chartDisplayName)
                    .font(.headline)
                Text(sensor.chartSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(sensor.sensorTypeLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(sensor.color.opacity(0.14), in: Capsule())
        }
    }

    private var valueLine: some View {
        Text(sensor.valueText)
            .font(.headline.monospacedDigit())
            .foregroundStyle(sensor.color)
    }

    private var modeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(sensor.supportedDisplayModes) { mode in
                modeButton(for: mode)
            }
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label("移除组件", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        Text(selectedMode == nil ? "未加入仪表盘" : "当前模式：\(selectedMode?.title ?? "")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var backgroundColor: Color {
        selectedMode != nil ? Color.blue.opacity(0.08) : Color.white.opacity(0.80)
    }

    private func modeButton(for mode: DashboardWidgetDisplayMode) -> some View {
        let isSelected = selectedMode == mode
        let canSelect = canSelectMode(mode)

        return Button {
            onSelect(mode)
        } label: {
            Label(mode.title, systemImage: mode.symbolName)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(
            (isSelected ? Color.blue.opacity(0.14) : Color.white.opacity(0.75)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
        .opacity(canSelect || isSelected ? 1 : 0.45)
        .disabled(!canSelect && !isSelected)
    }
}

private struct SettingToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 4)
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatusFactRow: View {
    let title: String
    let value: String
    let symbolName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .frame(width: 18)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DashboardSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            }
    }
}

private struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.97, blue: 1.00), Color(red: 0.90, green: 0.94, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.11, green: 0.43, blue: 0.58).opacity(0.08))
                .frame(width: 500, height: 500)
                .offset(x: 340, y: -280)

            Circle()
                .fill(Color(red: 0.97, green: 0.53, blue: 0.19).opacity(0.08))
                .frame(width: 420, height: 420)
                .offset(x: -320, y: 340)
        }
    }
}

// MARK: - QR Scan Sheet

struct QRScanSheet: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            phaseContent
                .navigationTitle("扫码配对")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            vm.cancelQRScan()
                            dismiss()
                        }
                        .disabled({
                            if case .pairing = vm.qrPhase { return true }
                            return false
                        }())
                    }
                }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch vm.qrPhase {
        case .idle, .scanning:
            scannerView
        case .pairing(let payload):
            pairingView(payload: payload)
        case .success:
            successView
        case .failed(let msg):
            failedView(message: msg)
        }
    }

    // MARK: Scanner

    private var scannerView: some View {
        ZStack {
            QRScannerView(
                onFound: { raw in vm.handleQRFound(raw) },
                onCameraError: { msg in vm.cameraError = msg }
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                if let err = vm.cameraError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                } else {
                    Text("将镜头对准主机端 PreConnect 显示的二维码")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
    }

    // MARK: Pairing in progress

    private func pairingView(payload: QRPayload) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.6)
                .padding(.top, 60)

            Text("正在配对…")
                .font(.title3.weight(.semibold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let server = payload.server {
                        LabeledContent("主机名") { Text(server) }
                    }
                    LabeledContent("地址") {
                        Text(payload.serviceBaseURL.host() ?? payload.endpointURL.absoluteString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ExpiryCountdown(expires: payload.expires)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: Success

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("配对成功")
                .font(.title.bold())
            Text("正在载入硬件数据…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("开始监控") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom)
        }
        .padding()
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)
            Text("配对失败")
                .font(.title.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                vm.resetQRScan()
            } label: {
                Label("重新扫码", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }
}

// MARK: - Expiry Countdown

struct ExpiryCountdown: View {
    let expires: Date
    @State private var remaining: TimeInterval = 0

    var body: some View {
        LabeledContent("有效期剩余") {
            Text(remaining > 0 ? formatted(remaining) : "已过期")
                .monospacedDigit()
                .foregroundStyle(remaining < 30 ? .red : .primary)
        }
        .onAppear { remaining = expires.timeIntervalSinceNow }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            remaining = expires.timeIntervalSinceNow
        }
    }

    private func formatted(_ t: TimeInterval) -> String {
        let m = max(0, Int(t) / 60)
        let s = max(0, Int(t) % 60)
        return String(format: "%d:%02d", m, s)
    }
}

