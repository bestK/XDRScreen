//
//  HostApp.swift
//  XDRScreen Mac host
//
//  Lightweight device utility UI: running state, pairing QR / key, permission
//  guidance and an explicit login-item toggle.
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement

/// Stable identifiers for scenes the menu bar item reopens.
enum HostWindowID {
    static let main = "main"
}

@main
struct XDRScreenHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = HostController.shared

    var body: some Scene {
        WindowGroup("XDRScreen 主机", id: HostWindowID.main) {
            ContentView(controller: controller)
        }
        .defaultSize(width: 620, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Always-available status and control while the main window is closed.
        // The menu observes the same HostController as the window, so its
        // status lines stay live.
        MenuBarExtra {
            MenuBarContentView(controller: controller)
        } label: {
            Image(systemName: "display")
                .accessibilityLabel("XDRScreen")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HostController.shared.start()
        HostController.shared.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HostController.shared.shutdownForTermination()
    }

    /// Closing the window must not end streaming for the connected iPad.
    /// The app keeps running in the menu bar; quitting from there still goes
    /// through `applicationWillTerminate` and the full shutdown path.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Menu bar

private struct MenuBarContentView: View {
    @ObservedObject var controller: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Read-only status, taken from the properties HostController already
        // publishes. These render as disabled menu items.
        Text("服务：\(controller.serviceStatus)")
        Text("iPad：\(controller.clientStatus)")
        Text("视频：\(controller.videoStatus)")
        Text("显示方式：\(controller.displayMode.title)")

        Divider()

        Button("显示主窗口") {
            showMainWindow()
        }

        Divider()

        Button("退出 XDRScreen") {
            // Never exit(0): this drives applicationWillTerminate, which
            // releases the virtual display and restores the arrangement.
            NSApplication.shared.terminate(nil)
        }
    }

    /// Reopens the main window when it was closed and raises it when it is
    /// merely behind other apps or minimized.
    private func showMainWindow() {
        openWindow(id: HostWindowID.main)
        NSApplication.shared.activate()
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Login item

enum LoginItemManager {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static var statusText: String {
        switch status {
        case .enabled: return "已启用"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered: return "未启用"
        case .notFound: return "不可用（需安装到“应用程序”并由系统签名）"
        @unknown default: return "未知状态"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - QR

enum QRCodeRenderer {
    static func image(for string: String) -> NSImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

// MARK: - Content

struct ContentView: View {
    @ObservedObject var controller: HostController

    @State private var qrImage: NSImage?
    @State private var launchAtLogin = LoginItemManager.isEnabled
    @State private var launchError: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusSection
                    displaySection
                    FileTransferSectionView(transfer: controller.fileTransfer)
                    pairingSection
                    permissionsSection
                    launchSection
                    diagnosticsSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            controller.start()
            controller.refreshPermissions()
            if qrImage == nil {
                qrImage = QRCodeRenderer.image(for: controller.pairingURL)
            }
            launchAtLogin = LoginItemManager.isEnabled
        }
        .onChange(of: controller.pairingURL) { _, newValue in
            qrImage = QRCodeRenderer.image(for: newValue)
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshPermissions()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("XDRScreen 主机")
                    .font(.headline)
                Text(controller.deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: controller.isListening ? "运行中" : "未运行",
                       active: controller.isListening)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Status

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                InfoRow(label: "服务", value: controller.serviceStatus)
                InfoRow(label: "iPad", value: controller.clientStatus)
                InfoRow(label: "视频", value: controller.videoStatus)
                if let error = controller.lastError {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        } label: {
            Text("运行状态").font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Display mode

    private var displaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("显示方式", selection: displayModeBinding) {
                    ForEach(HostDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(controller.displayMode == .mirror
                     ? "把 Mac 当前主屏（例如电视）的画面发送到 iPad。不会改变 Mac 的显示器排列，iPad 不会成为 Mac 的屏幕。"
                     : "创建与 iPad 面板同分辨率的 2x Retina 虚拟屏并只串流它。它是一块扩展桌面：电视上已有的窗口不会自动搬过去，也不会镜像电视。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("画质", selection: qualityBinding) {
                    ForEach(HostQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("\(controller.quality.title)：\(controller.quality.detail) 网络积压时会自动降低码率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("目标码率", selection: manualBitrateBinding) {
                    Text("跟随画质档位").tag(nil as Int?)
                    ForEach(manualBitrateChoices, id: \.self) { mbps in
                        Text("\(mbps) Mbps").tag(Optional(mbps))
                    }
                }
                .pickerStyle(.radioGroup)

                Text(manualBitrateCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                InfoRow(label: "专用屏",
                        value: controller.virtualDisplaySummary ?? "未创建（连接 iPad 后按需创建）")

                if controller.displayMode == .dedicated {
                    HStack(spacing: 8) {
                        Button("设为主屏") { controller.promoteVirtualDisplayToMain() }
                            .controlSize(.small)
                            .disabled(controller.virtualDisplaySummary == nil || controller.virtualDisplayIsMain)
                        Button("恢复原显示排列") { controller.restoreDisplayArrangement() }
                            .controlSize(.small)
                            .disabled(!controller.arrangementPromoted)
                        Button("打开显示器设置") { controller.openDisplaySettings() }
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    Text("“设为主屏”会把菜单栏移到 iPad 专用屏；退出应用或切回镜像时会恢复之前的排列。若系统拒绝，应用会先还原排列，请改在“系统设置 › 显示器”中手动拖动菜单栏。专用屏是扩展桌面，应用窗口需要你自己拖过去或在调度中心移动。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("该虚拟屏实测 EDR 余量为 1.0，属于 SDR；即使 iPad 面板支持 HDR，本模式也不会以 HDR 串流。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("选择会被记住，之后 iPad 连接时自动使用。切换显示方式会断开当前连接并让 iPad 自动重连。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("iPad 显示方式").font(.subheadline.weight(.semibold))
        }
    }

    private var displayModeBinding: Binding<HostDisplayMode> {
        Binding(
            get: { controller.displayMode },
            set: { controller.setDisplayMode($0) }
        )
    }

    private var qualityBinding: Binding<HostQuality> {
        Binding(
            get: { controller.quality },
            set: { controller.setQuality($0) }
        )
    }

    /// Presets offered in the window. A value pushed by the iPad client that
    /// is not one of them (the protocol allows 4–200 Mbps) is appended so the
    /// picker still shows a truthful selection instead of an empty row.
    private var manualBitrateChoices: [Int] {
        var choices = [10, 20, 30, 50, 80, 120]
        if let current = controller.manualBitrateMbps, !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
    }

    private var manualBitrateBinding: Binding<Int?> {
        Binding(
            get: { controller.manualBitrateMbps },
            set: { controller.setManualBitrate($0) }
        )
    }

    private var manualBitrateCaption: String {
        if let mbps = controller.manualBitrateMbps {
            return "当前目标码率 \(mbps) Mbps（手动值优先于画质档位；发送积压时仍会自动下调）。iPad 客户端也能设置，最后修改的一端生效。"
        }
        return "当前跟随「\(controller.quality.title)」档位的码率预算。iPad 客户端也能设置，最后修改的一端生效。"
    }

    // MARK: Pairing

    private var pairingSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 18) {
                qrView
                VStack(alignment: .leading, spacing: 8) {
                    Text("在 iPad 客户端中扫描二维码即可配对，之后打开客户端会自动连接。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("配对密钥")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(controller.pairingKey.isEmpty ? "生成中…" : controller.pairingKey)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(copied ? "已复制" : "复制密钥") { copyKey() }
                            .controlSize(.small)
                        Button("复制配对链接") { copyPairingURL() }
                            .controlSize(.small)
                    }

                    Text(controller.keyPersisted
                         ? "32 字节密钥保存在 macOS 钥匙串，仅通过二维码 / 剪贴板传递，不写入 Bonjour 广播或日志。"
                         : "警告：密钥未能写入钥匙串，本次运行使用临时密钥，重启后会变化。")
                        .font(.caption2)
                        .foregroundStyle(controller.keyPersisted ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        } label: {
            Text("配对").font(.subheadline.weight(.semibold))
        }
    }

    private var qrView: some View {
        Group {
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 156, height: 156)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 172, height: 172)
                    .overlay(
                        Text("二维码\n生成中")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "屏幕录制",
                    granted: controller.screenRecordingGranted,
                    detail: "ScreenCaptureKit 读取主显示器画面所必需。未授权时无法串流。",
                    requestTitle: "请求权限",
                    request: { controller.requestScreenRecording() },
                    openSettings: { controller.openScreenRecordingSettings() }
                )
                Divider()
                PermissionRow(
                    title: "辅助功能",
                    granted: controller.accessibilityGranted,
                    detail: "把 iPad 的触控、滚动与键盘事件注入 Mac 所必需；未授权时仍可观看，但不能控制。",
                    requestTitle: "请求授权",
                    request: { controller.requestAccessibility() },
                    openSettings: { controller.openAccessibilitySettings() }
                )
                HStack {
                    Text("更改授权后，屏幕录制通常需要重新启动本应用才会生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("刷新状态") { controller.refreshPermissions() }
                        .controlSize(.small)
                }
            }
            .padding(6)
        } label: {
            Text("权限").font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Launch at login

    private var launchSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("登录时自动启动 XDRScreen 主机", isOn: launchBinding)
                    .toggleStyle(.switch)
                Text("通过 macOS 登录项（SMAppService）注册。不会在首次运行时自动开启，也不会修改其他系统设置。当前状态：\(LoginItemManager.statusText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if LoginItemManager.requiresApproval {
                    Text("已在系统中注册，需要在“系统设置 › 通用 › 登录项与扩展”中允许。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        } label: {
            Text("启动").font(.subheadline.weight(.semibold))
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LoginItemManager.setEnabled(newValue)
                    launchAtLogin = LoginItemManager.isEnabled
                    launchError = LoginItemManager.requiresApproval
                        ? "已提交注册，需要在“系统设置 › 通用 › 登录项与扩展”中允许。"
                        : nil
                } catch {
                    launchError = "设置登录项失败：\(error.localizedDescription)"
                    launchAtLogin = LoginItemManager.isEnabled
                }
            }
        )
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if controller.eventLog.isEmpty {
                            Text("暂无事件")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(controller.eventLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
                HStack {
                    Spacer()
                    Button("复制诊断信息") { copyDiagnostics() }
                        .controlSize(.small)
                }
            }
            .padding(6)
        } label: {
            Text("诊断").font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Clipboard

    private func copyKey() {
        guard !controller.pairingKey.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controller.pairingKey, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func copyPairingURL() {
        guard !controller.pairingURL.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controller.pairingURL, forType: .string)
    }

    private func copyDiagnostics() {
        let lines = [
            "XDRScreen 主机诊断",
            "设备：\(controller.deviceName)",
            "服务：\(controller.serviceStatus)",
            "客户端：\(controller.clientStatus)",
            "视频：\(controller.videoStatus)",
            "显示方式：\(controller.displayMode.title)",
            "iPad 专用屏：\(controller.virtualDisplaySummary ?? "未创建")",
            "专用屏为主屏：\(controller.virtualDisplayIsMain ? "是" : "否")",
            "已提升排列：\(controller.arrangementPromoted ? "是" : "否")",
            "屏幕录制：\(controller.screenRecordingGranted ? "已授权" : "未授权")",
            "辅助功能：\(controller.accessibilityGranted ? "已授权" : "未授权")",
            "配对密钥已持久化：\(controller.keyPersisted ? "是" : "否")",
            "登录项：\(LoginItemManager.statusText)",
            "— 事件 —"
        ] + controller.eventLog
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - File transfer

private struct FileTransferSectionView: View {
    @ObservedObject var transfer: FileTransferService

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                dropZone

                HStack(spacing: 8) {
                    Button("发送文件…") { transfer.chooseFilesToSend() }
                        .controlSize(.small)
                        .disabled(!transfer.isConnected)
                    Text(transfer.isConnected ? "iPad 已连接，可以发送" : "连接 iPad 后可发送文件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                destinationRow

                Divider()

                transferList

                if let error = transfer.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Text("每个方向同一时刻只传输一个文件；单文件上限 4 GiB。iPad 发来的文件保存到上面的目录，同名时自动追加编号。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("文件传输").font(.subheadline.weight(.semibold))
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
                .foregroundStyle(
                    transfer.isConnected
                        ? Color.secondary.opacity(0.55)
                        : Color.secondary.opacity(0.25)
                )
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 18, weight: .regular))
                Text("把文件拖到这里发送到 iPad")
                    .font(.callout)
                Text("只接受文件，可一次拖入多个")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)

            FileDropZone(isEnabled: transfer.isConnected) { urls in
                transfer.sendFiles(at: urls)
            }
        }
        .frame(height: 84)
        .help("拖入常规文件即可发送；文件夹和符号链接会被拒绝。")
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Text("保存到")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(transfer.destinationPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(transfer.destinationPath)
            Spacer(minLength: 4)
            Button("选择…") { transfer.chooseDestination() }
                .controlSize(.small)
            Button("恢复默认") { transfer.restoreDefaultDestination() }
                .controlSize(.small)
        }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if transfer.items.isEmpty {
                Text("暂无传输记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(transfer.items.reversed()) { item in
                            row(for: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func row(for item: FileTransferItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.direction.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.direction.title)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)

                HStack(spacing: 6) {
                    Text(item.statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor(item.status))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sizeText(item))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if item.status.isActive {
                        Button("取消") { transfer.cancelTransfer(id: item.id) }
                            .controlSize(.mini)
                    }
                    if item.status == .completed,
                       item.direction == .receive,
                       item.localURL != nil {
                        Button("在 Finder 中显示") { transfer.revealInFinder(id: item.id) }
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    private func statusColor(_ status: FileTransferStatus) -> Color {
        switch status {
        case .waiting, .transferring: return .secondary
        case .completed: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        }
    }

    private func sizeText(_ item: FileTransferItem) -> String {
        // Refused inputs never got a size; do not claim "0 bytes / 0 bytes".
        if item.totalBytes == 0, item.status != .completed {
            return ""
        }
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.transferredBytes),
                                             countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.totalBytes),
                                              countStyle: .file)
        return "\(done) / \(total)"
    }
}

/// Drop target for `.fileURL` drags. SwiftUI has no first-class multi-file
/// drop area on macOS 15 that also gives us an explicit "only files" filter,
/// so this is a small NSView representable.
private struct FileDropZone: NSViewRepresentable {
    var isEnabled: Bool
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropNSView {
        let view = FileDropNSView()
        view.onDrop = onDrop
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: FileDropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.isEnabled = isEnabled
    }
}

private final class FileDropNSView: NSView {
    var onDrop: (([URL]) -> Void)?
    var isEnabled = true
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, !fileURLs(from: sender).isEmpty else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && !fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        let urls = fileURLs(from: sender)
        guard isEnabled, !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                     xRadius: 8,
                     yRadius: 8).fill()
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: options)
        return (objects as? [NSURL])?.map { $0 as URL } ?? []
    }
}

// MARK: - Small views

private struct StatusPill: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let requestTitle: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(granted ? "已授权" : "未授权")
                        .font(.caption)
                        .foregroundStyle(granted ? Color.green : Color.orange)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !granted {
                        Button(requestTitle, action: request)
                            .controlSize(.small)
                    }
                    Button("打开系统设置", action: openSettings)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
