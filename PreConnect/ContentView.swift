//
//  ContentView.swift
//  PreConnect 的主界面
//  Created by Prelina Montelli
//

// MARK: - 引入与常量
import SwiftUI
import Charts
import Combine
import Darwin

private enum AppSection: Hashable {
    case setup
    case dashboard
    case settings
    case about
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

private enum PerformanceNotice {
    static let pollingPausedOutsideDashboard = "为优化性能，监控面板外已暂停数据刷新"
}

// MARK: - 根视图容器

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var vm = AppViewModel()
    @State private var showScanner = false
    @State private var showGlobalHelpDialog = false
    @State private var selectedSection: AppSection? = .setup
    @State private var isDashboardTopBarVisible = false
    @State private var dashboardTopBarHideTask: Task<Void, Never>?
    @AppStorage(DashboardPreferenceKey.pollingInterval) private var pollingInterval = AppViewModel.defaultPollingInterval

    // MARK: - 计算属性

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

    private var isDashboardActive: Bool {
        activeSection == .dashboard && vm.isPaired
    }

    private var shouldPauseTelemetryPolling: Bool {
        vm.isPaired && activeSection != .dashboard
    }

    private var shouldShowPollingPausedNotice: Bool {
        vm.isPaired && activeSection != .dashboard
    }

    // MARK: - 主体视图

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(selectedSection: $selectedSection, vm: vm)
            } detail: {
                ZStack {
                    AppBackground()
                    detailContent
                }
                .overlay(alignment: .top) {
                    if shouldShowPollingPausedNotice {
                        Text(PerformanceNotice.pollingPausedOutsideDashboard)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
                            }
                            .padding(.top, 8)
                    }
                }
                .toolbar {
                    if isDashboardActive && isDashboardTopBarVisible {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if vm.isLoading {
                                ProgressView()
                            }

                            Button {
                                Task { await vm.refreshTelemetryOnce(showLoadingIndicator: true) }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
                .toolbar(isDashboardActive && !isDashboardTopBarVisible ? .hidden : .visible, for: .navigationBar)
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

            if showGlobalHelpDialog {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .transition(.opacity)

                AboutSupportDialog {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showGlobalHelpDialog = false
                    }
                }
                .padding(.horizontal, 20)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showGlobalHelpDialog)
        .onAppear {
            vm.updatePollingInterval(pollingInterval)
            if vm.isPaired {
                selectedSection = .dashboard
            }
            vm.setTelemetryPollingEnabled(!shouldPauseTelemetryPolling)
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

            if !isPaired {
                cancelDashboardTopBarAutoHide()
                isDashboardTopBarVisible = false
            }

            vm.setTelemetryPollingEnabled(!shouldPauseTelemetryPolling)
        }
        .onChange(of: activeSection) { _, section in
            if section != .dashboard {
                cancelDashboardTopBarAutoHide()
                isDashboardTopBarVisible = false
            }

            vm.setTelemetryPollingEnabled(!shouldPauseTelemetryPolling)
        }
    }

    // MARK: - 详情内容

    @ViewBuilder
    private var detailContent: some View {
        switch activeSection {
        case .setup:
            SetupWorkspaceView(vm: vm, showScanner: $showScanner)
        case .dashboard:
            if vm.isPaired {
                DashboardView(vm: vm, onUserInteraction: revealDashboardTopBarTemporarily)
            } else {
                DashboardLockedView(selectedSection: $selectedSection)
            }
        case .settings:
            SettingsView(vm: vm)
        case .about:
            AboutView {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showGlobalHelpDialog = true
                }
            }
        }
    }

    // MARK: - 顶部工具栏控制

    private func revealDashboardTopBarTemporarily() {
        guard isDashboardActive else { return }

        if !isDashboardTopBarVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isDashboardTopBarVisible = true
            }
        }

        cancelDashboardTopBarAutoHide()
        dashboardTopBarHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isDashboardActive else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDashboardTopBarVisible = false
                }
            }
        }
    }

    private func cancelDashboardTopBarAutoHide() {
        dashboardTopBarHideTask?.cancel()
        dashboardTopBarHideTask = nil
    }
}

// MARK: - 侧边栏

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
                Label("关于", systemImage: "info.circle")
                    .tag(AppSection.about)
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

                    if vm.isDemoMode {
                        Label("演示主机", systemImage: "sparkles.rectangle.stack")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
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
        .background(AppBackground())
        .navigationTitle("PreConnect")
    }
}

// MARK: - 连接与配对页面

private struct SetupWorkspaceView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var showScanner: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    Spacer(minLength: max(geometry.size.height * 0.12, 40))

                    SetupPairingFocusView(
                        isPaired: vm.isPaired,
                        onScanTap: {
                            vm.startQRScanning()
                            showScanner = true
                        },
                        onStartReviewDemoTap: {
                            vm.startReviewDemoMode()
                        },
                        onManualPayloadSubmit: { raw in
                            vm.startQRScanning()
                            vm.handleQRFound(raw)
                            showScanner = true
                        }
                    )

                    Spacer(minLength: max(geometry.size.height * 0.12, 40))
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct SetupPairingFocusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDrawOnActive = true
    @State private var showManualPayloadSheet = false
    @State private var manualPayloadInput = ""

    let isPaired: Bool
    let onScanTap: () -> Void
    let onStartReviewDemoTap: () -> Void
    let onManualPayloadSubmit: (String) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Text("欢迎使用PreConnect")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(adaptiveTextColor)

            Text("请使用主机端显示的二维码完成配对")
                .font(.title3)
                .foregroundStyle(adaptiveTextColor)

            qrCodeIcon
            

            Button(action: onScanTap) {
                HStack(spacing: 12) {
                    Text(isPaired ? "扫码配对" : "扫码配对")
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.blue)

            Button(action: onStartReviewDemoTap) {
                Label("演示主机", systemImage: "sparkles")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Text("用于进行演示")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            if shouldShowManualPairButton {
                Button {
                    showManualPayloadSheet = true
                } label: {
                    Label("调试：手动输入二维码载荷", systemImage: "keyboard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }


        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 40)
        .padding(.vertical, 44)
        .sheet(isPresented: $showManualPayloadSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 14) {
                    Text("请粘贴完整二维码 JSON 载荷")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $manualPayloadInput)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        let raw = manualPayloadInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty else { return }
                        onManualPayloadSubmit(raw)
                        showManualPayloadSheet = false
                    } label: {
                        Label("提交并配对", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualPayloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer(minLength: 0)
                }
                .padding(16)
                .navigationTitle("手动配对")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showManualPayloadSheet = false
                        }
                    }
                }
            }
        }
    }

    private var adaptiveTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    @ViewBuilder
    private var qrCodeIcon: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 92, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 220, height: 220)
                .symbolEffect(.drawOn.byLayer, options: .nonRepeating, isActive: isDrawOnActive)
                .onAppear {
                    isDrawOnActive = true
                    DispatchQueue.main.async {
                        isDrawOnActive = false
                    }
                }
        } else {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 92, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 220, height: 220)
        }
    }

    private var shouldShowManualPairButton: Bool {
#if targetEnvironment(simulator)
        true
#elseif DEBUG
        true
#else
        isDebuggerAttached
#endif
    }

    private var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

// MARK: - 监控面板页面

private struct DashboardView: View {
    @ObservedObject var vm: AppViewModel
    let onUserInteraction: () -> Void
    @AppStorage(DashboardPreferenceKey.widgetConfigurations) private var widgetConfigurationsRaw = "[]"

    private var widgetConfigurations: [DashboardWidgetConfig] {
        WidgetConfigurationStore.decode(widgetConfigurationsRaw)
    }

    private var activeWidgetConfigurations: [DashboardWidgetConfig] {
        let activeSensorIDs = Set(vm.chartableSensors.map(\.id))
        return widgetConfigurations.filter { activeSensorIDs.contains($0.sensorId) }
    }

    private var widgetStates: [DashboardWidgetState] {
        vm.widgetStates(for: activeWidgetConfigurations)
    }

    private var layoutResult: DashboardLayoutResult {
        DashboardLayoutEngine.layout(for: activeWidgetConfigurations)
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onUserInteraction()
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                onUserInteraction()
            }
        )
        .onAppear {
            reconcileInvalidWidgetConfigurationsIfNeeded()
            ensureDefaultWidgetsIfNeeded()
        }
        .onChange(of: vm.chartableSensors.map(\.id)) { _, _ in
            reconcileInvalidWidgetConfigurationsIfNeeded()
            ensureDefaultWidgetsIfNeeded()
        }
    }

    private func reconcileInvalidWidgetConfigurationsIfNeeded() {
        if activeWidgetConfigurations.count == widgetConfigurations.count {
            return
        }

        widgetConfigurationsRaw = WidgetConfigurationStore.encode(activeWidgetConfigurations)
    }

    private func ensureDefaultWidgetsIfNeeded() {
        guard activeWidgetConfigurations.isEmpty else { return }
        let defaults = vm.defaultWidgetConfigs()
        guard !defaults.isEmpty else { return }
        widgetConfigurationsRaw = WidgetConfigurationStore.encode(defaults)
    }
}

// MARK: - 监控小组件

private struct DashboardCanvasView: View {
    let layoutResult: DashboardLayoutResult
    let widgetStates: [DashboardWidgetState]

    private let canvasPadding: CGFloat = 10
    private let cellSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(geometry.size.width - canvasPadding * 2, 0)
            let usableHeight = max(geometry.size.height - canvasPadding * 2, 0)
            let occupiedRowCount = max(
                layoutResult.placements.map { $0.row + $0.span.rows }.max() ?? 1,
                1
            )
            let rawCellWidth = (usableWidth - cellSpacing * CGFloat(DashboardLayoutEngine.gridColumns - 1)) / CGFloat(DashboardLayoutEngine.gridColumns)
            let rawCellHeight = (usableHeight - cellSpacing * CGFloat(occupiedRowCount - 1)) / CGFloat(occupiedRowCount)
            let cellWidth = max(rawCellWidth, 20)
            let cellHeight = max(rawCellHeight, 20)

            ZStack(alignment: .topLeading) {
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
    }
}

private struct DashboardWidgetTile: View {
    let widget: DashboardWidgetState

    private var tileSpacing: CGFloat {
        widget.config.displayMode == .chart ? 14 : 9
    }

    private var tilePadding: CGFloat {
        widget.config.displayMode == .chart ? 18 : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tileSpacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(widget.sensor.sensorName, systemImage: widgetIcon)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.24))
                        .labelStyle(DashboardWidgetTitleLabelStyle(accent: widget.sensor.iconTint, tint: widget.sensor.softTint))
                    Text(widget.sensor.componentName)
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.38, green: 0.43, blue: 0.52))
                        .lineLimit(widget.config.displayMode == .chart ? 2 : 1)
                }
                Spacer()

                Text(widget.sensor.sensorTypeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(widget.sensor.iconTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(widget.sensor.softTint, in: Capsule())
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
        .padding(tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(widget.sensor.lineTint, lineWidth: 1)
        }
    }

    private var widgetIcon: String {
        switch widget.config.displayMode {
        case .chart: return "chart.xyaxis.line"
        case .value: return "number.square.fill"
        case .progress: return "gauge.with.needle.fill"
        }
    }
}

private struct DashboardWidgetTitleLabelStyle: LabelStyle {
    let accent: Color
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            configuration.title
        }
    }
}

private struct SensorWidgetChart: View {
    let samples: [MetricSample]
    let sensor: SensorDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sensor.valueText)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(sensor.strongColor)

            if samples.isEmpty {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(sensor.softTint.opacity(0.75))
                    .overlay {
                        Text("等待数据")
                            .foregroundStyle(Color(red: 0.44, green: 0.48, blue: 0.56))
                    }
            } else {
                Chart(samples) { sample in
                    AreaMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                        .foregroundStyle(sensor.strongColor.opacity(0.16))
                    LineMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(sensor.strongColor)

                    if let latest = samples.last, latest.id == sample.id {
                        PointMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                            .symbolSize(40)
                            .foregroundStyle(sensor.strongColor)
                        PointMark(x: .value("时间", sample.timestamp), y: .value("数值", sample.value))
                            .symbolSize(100)
                            .foregroundStyle(sensor.strongColor.opacity(0.16))
                    }
                }
                .chartYScale(domain: yAxisDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(sensor.lineTint)
                        AxisTick(stroke: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(sensor.lineTint)
                        AxisValueLabel()
                            .foregroundStyle(Color(red: 0.46, green: 0.50, blue: 0.57))
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(sensor.softTint.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var yAxisDomain: ClosedRange<Double> {
        let values = samples.map(\.value)
        guard let maxValue = values.max() else {
            return 0...100
        }
        return 0...(maxValue + 40)
    }
}

private struct ValueWidgetContent: View {
    let sensor: SensorDisplayItem

    var body: some View {
        GeometryReader { proxy in
            let isTight = proxy.size.height < 112

            VStack(alignment: .leading, spacing: isTight ? 2 : 4) {
                Text(sensor.valueText)
                    .font(.system(size: isTight ? 22 : 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(sensor.strongColor)

                if !isTight {
                    Text(sensor.valueSummaryText)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Color(red: 0.41, green: 0.45, blue: 0.53))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct ProgressWidgetContent: View {
    let sensor: SensorDisplayItem

    var body: some View {
        GeometryReader { proxy in
            let isTight = proxy.size.height < 112

            VStack(alignment: .leading, spacing: isTight ? 4 : 7) {
                Text(sensor.valueText)
                    .font(.system(size: isTight ? 21 : 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(sensor.strongColor)

                ProgressView(value: sensor.progressFraction ?? inferredFraction)
                    .controlSize(isTight ? .small : .regular)
                    .tint(sensor.strongColor)
                    .background(Color.white.opacity(0.7), in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inferredFraction: Double {
        guard let value = sensor.value else { return 0 }
        return Swift.min(Swift.max(value / 100.0, 0), 1)
    }
}

// MARK: - 监控辅助卡片

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
                    .chartYScale(domain: yAxisDomain)
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

    private var yAxisDomain: ClosedRange<Double> {
        let values = chart.samples.map(\.value)
        guard let maxValue = values.max() else {
            return 0...100
        }
        return 0...(maxValue + 40)
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
            Text("尚未与任何主机配对")
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
                Text("正在等待数据")
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

// MARK: - 设置页面

private struct SettingsView: View {
    let vm: AppViewModel
    @AppStorage(DashboardPreferenceKey.widgetConfigurations) private var widgetConfigurationsRaw = "[]"
    @AppStorage(DashboardPreferenceKey.pollingInterval) private var pollingInterval = AppViewModel.defaultPollingInterval
    @State private var warningMessage: String?
    @State private var frozenSensorGroups: [(category: SensorCategory, sensors: [SensorDisplayItem])] = []
    @State private var frozenSession: SessionInfo?
    @State private var widgetConfigurationsState: [DashboardWidgetConfig] = []
    @State private var layoutResultState = DashboardLayoutEngine.layout(for: [])
    @State private var selectableModesState: [String: Set<DashboardWidgetDisplayMode>] = [:]

    private var usedGridCells: Int {
        layoutResultState.placements.reduce(0) { partial, placement in
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
                    LazyVStack(alignment: .leading, spacing: 24) {
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
            frozenSensorGroups = vm.sensorsByCategory
            frozenSession = vm.session

            vm.updatePollingInterval(pollingInterval)
            let restored = WidgetConfigurationStore.decode(widgetConfigurationsRaw)
            if restored.isEmpty {
                let defaults = vm.defaultWidgetConfigs()
                if !defaults.isEmpty {
                    updateConfigurations(defaults, persistRaw: true)
                } else {
                    updateConfigurations([], persistRaw: false)
                }
            } else {
                updateConfigurations(restored, persistRaw: false)
            }
        }
        .onChange(of: pollingInterval) { _, newValue in
            vm.updatePollingInterval(newValue)
        }
        .onChange(of: widgetConfigurationsRaw) { _, newValue in
            let restored = WidgetConfigurationStore.decode(newValue)
            if restored != widgetConfigurationsState {
                updateConfigurations(restored, persistRaw: false)
            }
        }
    }

    private var sensorConfigurationPanel: some View {
        DashboardSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "仪表盘组件", subtitle: "为每个传感器选择合适的展示模式", symbolName: "square.grid.3x3.topleft.filled")

                if frozenSensorGroups.isEmpty {
                    Text("等待遥测数据后才能配置仪表盘组件。")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(frozenSensorGroups, id: \.category.id) { group in
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
                StatusFactRow(title: "当前组件数", value: "\(widgetConfigurationsState.count)", symbolName: "square.grid.3x2")
                StatusFactRow(title: "布局状态", value: layoutResultState.canFitAll ? "可完整显示" : "容量不足", symbolName: "aspectratio.fill")
                StatusFactRow(title: "自动缩放", value: layoutResultState.scaleTier.title, symbolName: "arrow.up.left.and.arrow.down.right")

                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(usedGridCells), total: Double(totalGridCells))
                        .tint(layoutResultState.canFitAll ? .blue : .orange)
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

                if let session = frozenSession {
                    StatusFactRow(title: "当前主机", value: session.serverName, symbolName: "desktopcomputer")
                    StatusFactRow(title: "远端地址", value: session.endpoint.absoluteString, symbolName: "network")
                    if let expiresAt = session.expiresAt {
                        StatusFactRow(title: "会话到期", value: expiresAt.formatted(date: .numeric, time: .shortened), symbolName: "clock.fill")
                    }

                    if vm.isDemoMode {
                        Text("当前连接为演示模式")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button(role: .destructive) {
                        frozenSession = nil
                        vm.disconnect()
                    } label: {
                        Label(vm.isDemoMode ? "退出演示模式" : "断开当前会话", systemImage: "xmark.circle.fill")
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
        widgetConfigurationsState.first(where: { $0.sensorId == sensorID })?.displayMode
    }

    private func setMode(_ mode: DashboardWidgetDisplayMode, for sensor: SensorDisplayItem) {
        guard sensor.supportedDisplayModes.contains(mode) else { return }

        var next = widgetConfigurationsState
        if let index = next.firstIndex(where: { $0.sensorId == sensor.id }) {
            if next[index].displayMode == mode { return }
            next[index].displayMode = mode
        } else {
            next.append(DashboardWidgetConfig(sensorId: sensor.id, displayMode: mode))
        }

        guard vm.canFitWidgets(next) else {
            warningMessage = "当前组件在自动缩放后仍无法容纳该组件。请先移除部分组件，或改用更紧凑的数字显示。"
            return
        }

        updateConfigurations(next, persistRaw: true)
    }

    private func removeWidget(for sensorID: String) {
        let next = widgetConfigurationsState.filter { $0.sensorId != sensorID }
        updateConfigurations(next, persistRaw: true)
    }

    private func canSelect(_ mode: DashboardWidgetDisplayMode, for sensor: SensorDisplayItem) -> Bool {
        guard sensor.supportedDisplayModes.contains(mode) else { return false }

        if selectedMode(for: sensor.id) == mode {
            return true
        }

        return selectableModesState[sensor.id]?.contains(mode) ?? false
    }

    private func updateConfigurations(_ next: [DashboardWidgetConfig], persistRaw: Bool) {
        widgetConfigurationsState = next
        layoutResultState = DashboardLayoutEngine.layout(for: next)
        selectableModesState = buildSelectableModes(configurations: next)

        guard persistRaw else { return }
        let encoded = WidgetConfigurationStore.encode(next)
        if encoded != widgetConfigurationsRaw {
            widgetConfigurationsRaw = encoded
        }
    }

    private func buildSelectableModes(configurations: [DashboardWidgetConfig]) -> [String: Set<DashboardWidgetDisplayMode>] {
        let sensors = frozenSensorGroups.flatMap(\.sensors)
        var result: [String: Set<DashboardWidgetDisplayMode>] = [:]

        for sensor in sensors {
            var selectable: Set<DashboardWidgetDisplayMode> = []
            for mode in sensor.supportedDisplayModes {
                var candidate = configurations
                if let index = candidate.firstIndex(where: { $0.sensorId == sensor.id }) {
                    candidate[index].displayMode = mode
                } else {
                    candidate.append(DashboardWidgetConfig(sensorId: sensor.id, displayMode: mode))
                }

                if vm.canFitWidgets(candidate) {
                    selectable.insert(mode)
                }
            }
            result[sensor.id] = selectable
        }

        return result
    }
}

// MARK: - 通用组件

private struct SensorCategorySection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

            LazyVStack(spacing: 14) {
                ForEach(Array(sensorRows.enumerated()), id: \.offset) { _, rowSensors in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(rowSensors) { sensor in
                            SensorConfiguratorCard(
                                sensor: sensor,
                                selectedMode: selectedMode(sensor.id),
                                canSelectMode: { mode in canSelectMode(mode, sensor) },
                                onSelect: { mode in onSelect(mode, sensor) },
                                onRemove: { onRemove(sensor.id) }
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        if rowSensors.count < columnCount {
                            ForEach(0..<(columnCount - rowSensors.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private var columnCount: Int {
        horizontalSizeClass == .regular ? 2 : 1
    }

    private var sensorRows: [[SensorDisplayItem]] {
        guard !sensors.isEmpty else { return [] }

        let count = max(columnCount, 1)
        return stride(from: 0, to: sensors.count, by: count).map { start in
            let end = min(start + count, sensors.count)
            return Array(sensors[start..<end])
        }
    }
}

private struct PollingIntervalPicker: View {
    @Environment(\.colorScheme) private var colorScheme

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
            (isSelected ? Color.blue.opacity(0.20) : neutralOptionBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
    }

    private var neutralOptionBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.04)
    }

    private func label(for value: TimeInterval) -> String {
        if value < 1 {
            return String(format: "%.1f 秒", value)
        }
        return String(format: "%.0f 秒", value)
    }
}

private struct SensorConfiguratorCard: View {
    @Environment(\.colorScheme) private var colorScheme

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
        if selectedMode != nil {
            return Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.10)
        }
        return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.04)
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
            (isSelected ? Color.blue.opacity(0.20) : neutralModeBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
        .opacity(canSelect || isSelected ? 1 : 0.45)
        .disabled(!canSelect && !isSelected)
    }

    private var neutralModeBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.04)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? Color.black : Color.white)
            .ignoresSafeArea()
    }
}

// MARK: - 扫码弹窗

struct QRScanSheet: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppBackground())
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

    // MARK: - 扫码界面

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

    // MARK: - 配对中

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

    // MARK: - 成功状态

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

    // MARK: - 失败状态

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

// MARK: - 倒计时视图

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

// MARK: - 预览

#if DEBUG
@available(iOS 17.0, *)
private struct SetupPairingFocusPreviewPlayground: View {
    @State private var isPaired = false
    @State private var scanTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("模拟已配对", isOn: $isPaired)
            Text("扫码按钮点击次数：\(scanTapCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            SetupPairingFocusView(
                isPaired: isPaired,
                onScanTap: { scanTapCount += 1 },
                onStartReviewDemoTap: { },
                onManualPayloadSubmit: { _ in }
            )
        }
        .padding(20)
        .background(AppBackground())
    }
}

@available(iOS 17.0, *)
private struct PollingIntervalPreviewPlayground: View {
    @State private var pollingInterval: TimeInterval = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("预览专用交互：点击下方频率按钮实时切换")
                .font(.caption)
                .foregroundStyle(.secondary)
            PollingIntervalPicker(selectedInterval: $pollingInterval)
        }
        .padding(20)
        .background(AppBackground())
    }
}

@available(iOS 17.0, *)
#Preview("ContentView - Light") {
    ContentView()
}

@available(iOS 17.0, *)
#Preview("ContentView - Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}

@available(iOS 17.0, *)
#Preview("Setup Pairing - Interactive", traits: .sizeThatFitsLayout) {
    SetupPairingFocusPreviewPlayground()
}

@available(iOS 17.0, *)
#Preview("Polling Interval - Interactive", traits: .sizeThatFitsLayout) {
    PollingIntervalPreviewPlayground()
}

@available(iOS 17.0, *)
#Preview("Expiry Countdown", traits: .sizeThatFitsLayout) {
    ExpiryCountdown(expires: Date().addingTimeInterval(75))
        .padding(20)
}
#endif

