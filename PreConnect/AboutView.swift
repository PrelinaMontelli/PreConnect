//
//  AboutView.swift
//  PreConnect 的关于页面
//  Created by Prelina Montelli
//

import SwiftUI
import UIKit

// MARK: - 关于页面

struct AboutView: View {
    @State private var isHelpDialogPresented = false
    private let buildInfo = AboutBuildInfo.current

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color.white,
                    Color(red: 0.91, green: 0.95, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                Image("LaunchIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 144, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 20, x: 0, y: 12)

                Text("PreConnect")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.24))

                VStack(spacing: 10) {
                    AboutMetaRow(title: "版本号", value: buildInfo.versionText)
                    AboutMetaRow(title: "Build 时间", value: buildInfo.buildTimeText)
                    AboutMetaRow(title: "版权", value: "©Prelina Montelli")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 360)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1)
                }

                Button("需要帮助？") {
                    isHelpDialogPresented = true
                }
                .font(.headline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.16, green: 0.42, blue: 0.95))

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .sheet(isPresented: $isHelpDialogPresented) {
            AboutSupportDialog()
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
        }
    }
}

// MARK: - 帮助弹窗

private struct AboutSupportDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var didCopyEmail = false

    private let supportEmail = "Prelinakaren@outlook.com"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("需要帮助？")
                        .font(.title2.bold())
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("联系邮箱")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Text(supportEmail)
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            UIPasteboard.general.string = supportEmail
                            didCopyEmail = true
                        } label: {
                            Image(systemName: didCopyEmail ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(didCopyEmail ? Color.green : Color.white)
                                .frame(width: 36, height: 36)
                                .background(
                                    didCopyEmail ? Color.green.opacity(0.14) : Color.blue,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(didCopyEmail ? "已复制邮箱" : "复制邮箱")
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                Button {
                    composeMail()
                } label: {
                    Label("发送邮件", systemImage: "envelope.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.16, green: 0.42, blue: 0.95))

                if didCopyEmail {
                    Text("邮箱地址已复制到剪贴板")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
            }
        }
    }

    private func composeMail() {
        guard let encodedEmail = supportEmail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:\(encodedEmail)") else {
            return
        }

        openURL(url)
    }
}

// MARK: - 信息行组件

private struct AboutMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.24))
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 构建信息

private struct AboutBuildInfo {
    let versionText: String
    let buildTimeText: String

    static var current: AboutBuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketingVersion = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = info["CFBundleVersion"] as? String ?? "1"

        return AboutBuildInfo(
            versionText: "v\(marketingVersion) (\(buildNumber))",
            buildTimeText: inferredBuildTimeText()
        )
    }

    private static func inferredBuildTimeText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let executableDate = try? Bundle.main.executableURL?
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let bundleDate = try? Bundle.main.bundleURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let buildDate = executableDate ?? bundleDate

        return formatter.string(from: buildDate ?? Date())
    }
}

// MARK: - 预览

#Preview("About - Light") {
    AboutView()
}

#Preview("About - Dark") {
    AboutView()
        .preferredColorScheme(.dark)
}
