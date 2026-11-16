//
//  ClientApp.swift
//  XDRScreen (iPad client)
//
//  App entry point, the root remote-screen controller and the pairing camera.
//  Deliberately a tool, not a landing page: while a stream is live the screen
//  is the Mac, and the only chrome is a collapsed "控制" tab that expands into
//  a compact bar when asked.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct XDRScreenApp: App {
    var body: some Scene {
        WindowGroup {
            ClientRootView()
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
        }
    }
}

private struct ClientRootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ClientViewController {
        ClientViewController()
    }

    func updateUIViewController(_ uiViewController: ClientViewController, context: Context) {}
}

// MARK: - Palette

private enum Palette {
    static let panel = UIColor(red: 0.055, green: 0.06, blue: 0.072, alpha: 0.97)
    static let stroke = UIColor(white: 1, alpha: 0.13)
    static let primary = UIColor(white: 0.95, alpha: 1)
    static let secondary = UIColor(white: 0.66, alpha: 1)
    static let tertiary = UIColor(white: 0.43, alpha: 1)
    static let positive = UIColor(red: 0.36, green: 0.86, blue: 0.55, alpha: 1)
    static let warning = UIColor(red: 1.0, green: 0.72, blue: 0.31, alpha: 1)
    static let negative = UIColor(red: 1.0, green: 0.42, blue: 0.38, alpha: 1)
    static let chrome = UIColor(white: 0.04, alpha: 0.74)
}

// MARK: - Root controller

final class ClientViewController: UIViewController {

    private let controller = ClientController()
    private let displayView = ClientVideoView()
    private let touchView = TouchView()

    /// Holds the picture and the touch surface so one transform zooms both.
    /// The setup panel, control chrome and toast stay on `view`, outside this
    /// container, and therefore never scale. `clipsToBounds` is left off (the
    /// root view clips instead) so the zoomed picture is not cropped to the
    /// container's unscaled bounds.
    private let viewportContainer = UIView()
    private var viewport = ViewportTransform()

    private let setupPanel = UIView()
    private let headerLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let hostsTitleLabel = UILabel()
    private let hostsStack = UIStackView()
    private let emptyHostsLabel = UILabel()
    private let buttonsStack = UIStackView()
    private let autoConnectRow = UIStackView()
    private let autoConnectSwitch = UISwitch()
    private let hintLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private let controlTab = UIButton(type: .system)
    private let controlBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let barDot = UIView()
    private let barLabel = UILabel()
    private let fitButton = UIButton(type: .system)
    private let bitrateButton = UIButton(type: .system)
    private let fileButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let reconnectButton = UIButton(type: .system)
    private let disconnectButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)

    private let toastContainer = UIView()
    private let toastLabel = UILabel()

    private var latest = ClientSnapshot()
    private var fileCancellables = Set<AnyCancellable>()
    private var barExpanded = false
    private var statsTimer: Timer?
    private var autoCollapseWork: DispatchWorkItem?
    private var toastHideWork: DispatchWorkItem?
    private var lastShownStatusMessage: String?

    /// The controller owns the service so binding follows the session exactly;
    /// the UI only observes it.
    private var fileTransfer: FileTransferService { controller.fileTransfer }

    private var pixelScale: CGFloat {
        view.window?.screen.nativeScale ?? traitCollection.displayScale
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        // Zoomed content extends past the screen; the root clips it, not the
        // container (whose own bounds are still the unscaled screen).
        view.clipsToBounds = true

        viewportContainer.translatesAutoresizingMaskIntoConstraints = false
        viewportContainer.backgroundColor = .black
        viewportContainer.clipsToBounds = false
        view.addSubview(viewportContainer)

        displayView.translatesAutoresizingMaskIntoConstraints = false
        touchView.translatesAutoresizingMaskIntoConstraints = false
        viewportContainer.addSubview(displayView)
        viewportContainer.addSubview(touchView)
        NSLayoutConstraint.activate([
            viewportContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewportContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewportContainer.topAnchor.constraint(equalTo: view.topAnchor),
            viewportContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            displayView.leadingAnchor.constraint(equalTo: viewportContainer.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: viewportContainer.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: viewportContainer.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: viewportContainer.bottomAnchor),
            touchView.leadingAnchor.constraint(equalTo: viewportContainer.leadingAnchor),
            touchView.trailingAnchor.constraint(equalTo: viewportContainer.trailingAnchor),
            touchView.topAnchor.constraint(equalTo: viewportContainer.topAnchor),
            touchView.bottomAnchor.constraint(equalTo: viewportContainer.bottomAnchor)
        ])

        buildSetupPanel()
        buildControlChrome()
        buildToast()

        touchView.videoRectProvider = { [weak self] in
            self?.displayView.playbackRect ?? .zero
        }
        touchView.onInput = { [weak self] message in
            self?.controller.sendInput(message)
        }
        touchView.onKeyboardStateChange = { [weak self] active in
            self?.keyboardStateChanged(active)
        }
        // Zoom state lives in the controller; the touch view only reports
        // gesture deltas and asks which scale is current.
        touchView.zoomScaleProvider = { [weak self] in
            self?.viewport.scale ?? 1
        }
        touchView.onPinch = { [weak self] scaleFactor, midpoint, viewDelta in
            guard let self else { return }
            // The midpoint moved with the fingers: pan first, then zoom about
            // the current midpoint so the picture stays under them.
            self.viewport.pan(byViewDelta: viewDelta)
            self.viewport.zoom(by: scaleFactor, anchorViewPoint: midpoint)
            self.applyViewport()
        }
        touchView.onPan = { [weak self] viewDelta in
            guard let self else { return }
            self.viewport.pan(byViewDelta: viewDelta)
            self.applyViewport()
        }

        displayView.onNeedKeyframe = { [weak self] in
            self?.controller.requestKeyframe()
        }
        displayView.onFirstFrame = { [weak self] in
            self?.controller.markFirstFrameRendered()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        displayView.onRenderFailure = { [weak self] message in
            self?.controller.reportRenderFailure(message)
        }
        displayView.onRendererUnavailable = { [weak self] message, format in
            self?.controller.reportRendererUnavailable(message, format: format)
        }

        controller.attach(displayView: displayView)
        controller.onSnapshot = { [weak self] snapshot in
            self?.apply(snapshot)
        }

        // A drop only adds a file to the send queue; it does not touch the
        // touch surface, so single-finger mouse input and pinch zoom behave
        // exactly as before while the picture is on screen.
        viewportContainer.addInteraction(UIDropInteraction(delegate: self))

        fileTransfer.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.showToast(message)
            }
            .store(in: &fileCancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        controller.updateDisplayCapabilities(interfaceSize: view.bounds.size, scale: pixelScale)
        controller.start()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        statsTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startStatsTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statsTimer?.invalidate()
        statsTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controller.updateDisplayCapabilities(interfaceSize: view.bounds.size, scale: pixelScale)
        // Rotation / split-view resize: the container bounds are the new
        // viewport, and the old translation is re-clamped so the picture
        // still covers it. 1× stays 1×.
        viewport.setViewportSize(viewportContainer.bounds.size)
        applyViewport()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    @objc private func appDidEnterBackground() {
        touchView.releaseAllInput()
        controller.handleDidEnterBackground()
    }

    @objc private func appWillEnterForeground() {
        controller.handleWillEnterForeground()
    }

    @objc private func appWillTerminate() {
        // Removes any unfinished `.part` file before the process exits.
        controller.handleWillTerminate()
    }

    // MARK: - Viewport zoom

    /// Installs the current zoom/pan on the container. Both the picture and the
    /// touch surface are inside it, so touch coordinates stay in the same
    /// (unscaled) space while the screen shows the magnified result.
    private func applyViewport() {
        viewportContainer.transform = viewport.containerTransform
        updateFitButton()
    }

    /// 「适应」: back to 1× and centred.
    @objc private func fitTapped() {
        viewport.reset()
        applyViewport()
    }

    private func updateFitButton() {
        fitButton.isEnabled = viewport.isZoomed
    }

    // MARK: - Setup panel

    private func buildSetupPanel() {
        setupPanel.translatesAutoresizingMaskIntoConstraints = false
        setupPanel.backgroundColor = Palette.panel
        setupPanel.layer.cornerRadius = 16
        setupPanel.layer.cornerCurve = .continuous
        setupPanel.layer.borderWidth = 1 / UIScreen.main.scale
        setupPanel.layer.borderColor = Palette.stroke.cgColor
        view.addSubview(setupPanel)

        NSLayoutConstraint.activate([
            setupPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            setupPanel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            setupPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            setupPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            setupPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])

        headerLabel.text = "连接 Mac"
        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = Palette.secondary
        headerLabel.setContentHuggingPriority(.required, for: .horizontal)

        spinner.color = Palette.secondary
        spinner.hidesWhenStopped = true

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = UIStackView(arrangedSubviews: [headerLabel, spacer, spinner])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textColor = Palette.primary
        statusLabel.numberOfLines = 0

        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Palette.secondary
        detailLabel.numberOfLines = 0

        hostsTitleLabel.text = "附近的 Mac"
        hostsTitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hostsTitleLabel.textColor = Palette.tertiary

        hostsStack.axis = .vertical
        hostsStack.spacing = 6

        emptyHostsLabel.text = "正在查找同一网络中的 Mac…"
        emptyHostsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        emptyHostsLabel.textColor = Palette.tertiary
        emptyHostsLabel.numberOfLines = 0

        buttonsStack.axis = .vertical
        buttonsStack.spacing = 8

        let autoConnectLabel = UILabel()
        autoConnectLabel.text = "启动时自动连接"
        autoConnectLabel.font = .systemFont(ofSize: 13, weight: .regular)
        autoConnectLabel.textColor = Palette.secondary
        let autoSpacer = UIView()
        autoSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        autoConnectSwitch.onTintColor = Palette.positive
        autoConnectSwitch.addTarget(self, action: #selector(autoConnectChanged), for: .valueChanged)
        autoConnectRow.axis = .horizontal
        autoConnectRow.alignment = .center
        autoConnectRow.spacing = 8
        autoConnectRow.addArrangedSubview(autoConnectLabel)
        autoConnectRow.addArrangedSubview(autoSpacer)
        autoConnectRow.addArrangedSubview(autoConnectSwitch)

        hintLabel.text = "单指点击／拖动＝鼠标；长按或双指轻点＝右键；双指滑动＝滚动。连接后可点上方控制栏的键盘按钮输入文字。\n若找不到 Mac：确认同一 Wi-Fi，并在“设置 › 隐私与安全性 › 本地网络”中允许 XDRScreen。"
        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = Palette.tertiary
        hintLabel.numberOfLines = 0

        let content = UIStackView(arrangedSubviews: [
            headerRow, statusLabel, detailLabel, hostsTitleLabel, hostsStack,
            emptyHostsLabel, buttonsStack, autoConnectRow, hintLabel
        ])
        content.axis = .vertical
        content.spacing = 12
        content.setCustomSpacing(5, after: statusLabel)
        content.setCustomSpacing(10, after: detailLabel)
        content.setCustomSpacing(4, after: hostsTitleLabel)
        content.setCustomSpacing(14, after: buttonsStack)
        content.translatesAutoresizingMaskIntoConstraints = false
        setupPanel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: setupPanel.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: setupPanel.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: setupPanel.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: setupPanel.bottomAnchor, constant: -18)
        ])
    }

    @objc private func autoConnectChanged() {
        controller.setAutoConnect(autoConnectSwitch.isOn)
    }

    // MARK: - Control chrome

    private func buildControlChrome() {
        var tabConfig = UIButton.Configuration.plain()
        tabConfig.title = "控制"
        tabConfig.image = UIImage(systemName: "chevron.down")
        tabConfig.imagePlacement = .trailing
        tabConfig.imagePadding = 6
        tabConfig.baseForegroundColor = Palette.primary
        tabConfig.background.backgroundColor = Palette.chrome
        tabConfig.background.cornerRadius = 15
        tabConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        tabConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        tabConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12, weight: .medium)
            return out
        }
        controlTab.configuration = tabConfig
        controlTab.translatesAutoresizingMaskIntoConstraints = false
        controlTab.layer.borderWidth = 1 / UIScreen.main.scale
        controlTab.layer.borderColor = Palette.stroke.cgColor
        controlTab.isHidden = true
        controlTab.addAction(UIAction { [weak self] _ in
            self?.setBarExpanded(true)
        }, for: .touchUpInside)
        view.addSubview(controlTab)

        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.layer.cornerRadius = 12
        controlBar.layer.cornerCurve = .continuous
        controlBar.clipsToBounds = true
        controlBar.layer.borderWidth = 1 / UIScreen.main.scale
        controlBar.layer.borderColor = Palette.stroke.cgColor
        controlBar.isHidden = true
        view.addSubview(controlBar)

        barDot.backgroundColor = Palette.positive
        barDot.layer.cornerRadius = 4
        barDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            barDot.widthAnchor.constraint(equalToConstant: 8),
            barDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        barLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        barLabel.textColor = Palette.primary
        barLabel.numberOfLines = 1
        barLabel.lineBreakMode = .byTruncatingMiddle
        barLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        barLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureFitButton()
        configureChromeButton(bitrateButton, systemName: "speedometer", action: #selector(bitrateTapped))
        bitrateButton.accessibilityLabel = "码率"
        configureChromeButton(fileButton, systemName: "arrow.up.arrow.down", action: #selector(filesTapped))
        fileButton.accessibilityLabel = "文件"
        configureChromeButton(keyboardButton, systemName: "keyboard", action: #selector(toggleKeyboard))
        configureChromeButton(reconnectButton, systemName: "arrow.clockwise", action: #selector(reconnectTapped))
        configureChromeButton(disconnectButton, systemName: "xmark.circle", action: #selector(disconnectTapped))
        configureChromeButton(collapseButton, systemName: "chevron.up", action: #selector(collapseTapped))

        let stack = UIStackView(arrangedSubviews: [
            barDot, barLabel, fitButton, bitrateButton, fileButton,
            keyboardButton, reconnectButton, disconnectButton, collapseButton
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlBar.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            controlTab.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            controlTab.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlTab.heightAnchor.constraint(equalToConstant: 30),
            controlBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            controlBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            controlBar.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            controlBar.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: controlBar.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: controlBar.contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: controlBar.contentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: controlBar.contentView.bottomAnchor, constant: -7)
        ])
    }

    /// 「适应」 sits with the other chrome buttons. It is disabled at 1× where
    /// there is nothing to reset.
    private func configureFitButton() {
        var config = UIButton.Configuration.plain()
        config.title = "适应"
        config.baseForegroundColor = Palette.primary
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12, weight: .medium)
            return out
        }
        fitButton.configuration = config
        fitButton.translatesAutoresizingMaskIntoConstraints = false
        fitButton.isEnabled = false
        fitButton.accessibilityLabel = "适应画面"
        fitButton.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            fitButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func configureChromeButton(_ button: UIButton, systemName: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.baseForegroundColor = Palette.primary
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func buildToast() {
        toastContainer.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.backgroundColor = UIColor(white: 0.05, alpha: 0.9)
        toastContainer.layer.cornerRadius = 10
        toastContainer.layer.cornerCurve = .continuous
        toastContainer.layer.borderWidth = 1 / UIScreen.main.scale
        toastContainer.layer.borderColor = Palette.stroke.cgColor
        toastContainer.alpha = 0
        toastContainer.isHidden = true
        toastContainer.isUserInteractionEnabled = false
        view.addSubview(toastContainer)

        toastLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        toastLabel.textColor = Palette.primary
        toastLabel.numberOfLines = 3
        toastLabel.textAlignment = .center
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            toastContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toastContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            toastContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            toastLabel.leadingAnchor.constraint(equalTo: toastContainer.leadingAnchor, constant: 12),
            toastLabel.trailingAnchor.constraint(equalTo: toastContainer.trailingAnchor, constant: -12),
            toastLabel.topAnchor.constraint(equalTo: toastContainer.topAnchor, constant: 8),
            toastLabel.bottomAnchor.constraint(equalTo: toastContainer.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Snapshot application

    private func apply(_ snapshot: ClientSnapshot) {
        let previousPhase = latest.phase
        latest = snapshot

        if snapshot.phase == .streaming, previousPhase != .streaming {
            setBarExpanded(false)
            UIApplication.shared.isIdleTimerDisabled = true
        } else if snapshot.phase != .streaming {
            UIApplication.shared.isIdleTimerDisabled = false
            if previousPhase == .streaming {
                // The Mac may have closed the session mid-drag. Release every
                // button/key locally so nothing stays pressed when it returns.
                touchView.releaseAllInput()
                _ = touchView.resignFirstResponder()
            }
        }

        // A new video format or a reconnect can change the layout the picture
        // is fitted into. Re-clamp so an existing zoom never leaves a blank
        // edge; at 1× this is a no-op and the picture stays 1×.
        viewport.setViewportSize(viewportContainer.bounds.size)
        applyViewport()

        renderSetup()
        renderChrome()

        if snapshot.phase == .streaming,
           let message = snapshot.lastStatusMessage,
           message != lastShownStatusMessage {
            lastShownStatusMessage = message
            showToast(message)
        } else if snapshot.lastStatusMessage == nil {
            lastShownStatusMessage = nil
        }
    }

    private func renderSetup() {
        let streaming = latest.phase == .streaming
        setupPanel.isHidden = streaming
        touchView.isUserInteractionEnabled = streaming

        statusLabel.text = statusTitle()
        statusLabel.textColor = statusColor()
        detailLabel.text = detailText()
        autoConnectRow.isHidden = !latest.hasPairing
        if autoConnectSwitch.isOn != latest.autoConnect {
            autoConnectSwitch.setOn(latest.autoConnect, animated: false)
        }

        switch latest.phase {
        case .connecting, .handshaking, .reconnecting:
            spinner.startAnimating()
        default:
            spinner.stopAnimating()
        }

        let showsHosts = !streaming && phaseShowsHosts(latest.phase)
        rebuildHosts(showsHosts: showsHosts)
        rebuildButtons()
    }

    private func renderChrome() {
        let streaming = latest.phase == .streaming
        if !streaming {
            barExpanded = false
            autoCollapseWork?.cancel()
            autoCollapseWork = nil
        }
        controlTab.isHidden = !streaming || barExpanded
        controlBar.isHidden = !(streaming && barExpanded)
        updateBarContent()
    }

    private func phaseShowsHosts(_ phase: ClientSnapshot.Phase) -> Bool {
        switch phase {
        case .idle, .searching, .failed, .reconnecting, .paused:
            return true
        case .connecting, .handshaking, .streaming:
            return false
        }
    }

    private func statusTitle() -> String {
        switch latest.phase {
        case .idle:
            return latest.hosts.isEmpty ? "等待 Mac" : "选择 Mac"
        case .searching:
            return "正在查找"
        case .connecting(let host):
            return "连接 \(host)"
        case .handshaking:
            return "建立加密会话"
        case .streaming:
            return "已连接"
        case .reconnecting(let host):
            return "重新连接 \(host)"
        case .failed:
            return "连接失败"
        case .paused:
            return "已暂停"
        }
    }

    private func statusColor() -> UIColor {
        switch latest.phase {
        case .failed:
            return Palette.negative
        case .reconnecting:
            return Palette.warning
        case .streaming:
            return Palette.positive
        default:
            return Palette.primary
        }
    }

    private func detailText() -> String {
        var lines: [String] = []
        if !latest.detail.isEmpty {
            lines.append(latest.detail)
        }
        switch latest.phase {
        case .failed where latest.needsRepair:
            break
        case .idle, .searching, .paused:
            if latest.hasPairing, let host = latest.pairedHostName {
                lines.append("已配对：\(host)。密钥保存在本机钥匙串。")
            } else if !latest.hasPairing {
                lines.append("在 Mac 上启动 XDRScreen，允许屏幕录制，然后选择列表中的 Mac 进行配对。")
            }
            if latest.needsRepair {
                lines.append("密钥可能已失效，请重新扫描二维码。")
            }
        default:
            break
        }
        // Renderer trouble can arrive before the first frame, while the setup
        // panel is still the visible surface. Show it here instead of waiting
        // for the streaming-phase toast.
        if latest.phase != .streaming,
           let message = latest.lastStatusMessage,
           !message.isEmpty,
           !lines.contains(message) {
            lines.append(message)
        }
        return lines.joined(separator: "\n")
    }

    private func rebuildHosts(showsHosts: Bool) {
        for arranged in hostsStack.arrangedSubviews {
            hostsStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        let hosts = showsHosts ? Array(latest.hosts.prefix(4)) : []
        hostsTitleLabel.isHidden = hosts.isEmpty
        emptyHostsLabel.isHidden = !hosts.isEmpty || !showsHosts
        if showsHosts, hosts.isEmpty {
            emptyHostsLabel.text = latest.hasPairing
                ? "正在查找 \(latest.pairedHostName ?? "Mac")…"
                : "正在查找同一网络中的 Mac…"
        }

        for host in hosts {
            var config = UIButton.Configuration.filled()
            config.title = host.name
            if latest.hasPairing {
                config.subtitle = latest.pairedHostName == host.name
                    ? "已配对 · 点按连接"
                    : "将使用已保存的密钥"
            } else {
                config.subtitle = "点按配对"
            }
            config.titleAlignment = .leading
            config.baseForegroundColor = Palette.primary
            config.baseBackgroundColor = UIColor(white: 1, alpha: 0.07)
            config.background.cornerRadius = 9
            config.background.strokeColor = Palette.stroke
            config.background.strokeWidth = 1 / UIScreen.main.scale
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
            config.image = UIImage(systemName: "chevron.right")
            config.imagePlacement = .trailing
            config.imagePadding = 8
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 14, weight: .medium)
                return out
            }
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                out.foregroundColor = Palette.secondary
                return out
            }

            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .fill
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }
                self?.handleHostTap(host.name, anchor: button)
            }, for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 46).isActive = true
            hostsStack.addArrangedSubview(button)
        }
    }

    private func rebuildButtons() {
        for arranged in buttonsStack.arrangedSubviews {
            buttonsStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        switch latest.phase {
        case .failed:
            addButton("重试连接", role: .primary) { [weak self] in
                self?.controller.retryConnection()
            }
            if latest.hasPairing {
                addButton("重新配对…", role: .secondary) { [weak self] in
                    self?.repairCurrentPairing()
                }
            }
        case .idle, .searching, .paused:
            if latest.hasPairing, let host = latest.pairedHostName {
                addButton("连接 \(host)", role: .primary) { [weak self] in
                    self?.controller.connect(toHostNamed: host)
                }
                addButton("重新配对…", role: .secondary) { [weak self] in
                    self?.repairCurrentPairing()
                }
                addButton("忘记配对", role: .destructive) { [weak self] in
                    self?.confirmForgetPairing()
                }
            } else {
                addButton("重新搜索", role: .secondary) { [weak self] in
                    self?.controller.restartDiscovery()
                }
            }
        case .reconnecting:
            addButton("立即重试", role: .secondary) { [weak self] in
                self?.controller.retryConnection()
            }
            addButton("断开", role: .secondary) { [weak self] in
                self?.controller.disconnect()
            }
        case .connecting, .handshaking:
            addButton("断开", role: .secondary) { [weak self] in
                self?.controller.disconnect()
            }
        case .streaming:
            break
        }
    }

    private enum ButtonRole {
        case primary
        case secondary
        case destructive
    }

    private func addButton(_ title: String, role: ButtonRole, action: @escaping () -> Void) {
        var config: UIButton.Configuration
        switch role {
        case .primary:
            config = .filled()
            config.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
            config.baseForegroundColor = Palette.primary
        case .secondary:
            config = .plain()
            config.baseForegroundColor = Palette.secondary
        case .destructive:
            config = .plain()
            config.baseForegroundColor = Palette.negative
        }
        config.title = title
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .medium)
            return out
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        buttonsStack.addArrangedSubview(button)
    }

    // MARK: - Pairing flow

    private func handleHostTap(_ hostName: String, anchor: UIView) {
        if latest.hasPairing, latest.pairedHostName == hostName {
            controller.connect(toHostNamed: hostName)
            return
        }
        if latest.hasPairing {
            let alert = UIAlertController(
                title: hostName,
                message: "将使用这台 iPad 已保存的密钥连接。如果密钥与 Mac 不匹配，需要重新配对。",
                preferredStyle: .actionSheet
            )
            alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak self] _ in
                self?.controller.connect(toHostNamed: hostName)
            })
            alert.addAction(UIAlertAction(title: "重新配对…", style: .default) { [weak self] _ in
                self?.startPairing(hostName: hostName, anchor: anchor)
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            presentSheet(alert, anchor: anchor)
        } else {
            startPairing(hostName: hostName, anchor: anchor)
        }
    }

    private func repairCurrentPairing() {
        guard let host = latest.pairedHostName else {
            controller.restartDiscovery()
            return
        }
        startPairing(hostName: host, anchor: setupPanel)
    }

    private func startPairing(hostName: String, anchor: UIView?) {
        let alert = UIAlertController(
            title: "与 \(hostName) 配对",
            message: "在 Mac 上打开 XDRScreen，扫描窗口里的二维码；也可以手动粘贴 32 字节密钥。",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "扫描二维码", style: .default) { [weak self] _ in
            self?.presentScanner(hostName: hostName)
        })
        alert.addAction(UIAlertAction(title: "手动输入密钥", style: .default) { [weak self] _ in
            self?.presentManualEntry(hostName: hostName)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSheet(alert, anchor: anchor)
    }

    private func presentScanner(hostName: String) {
        // The caller is often an action-sheet handler; `presentSafely` waits
        // for that sheet to finish dismissing before showing the camera.
        let scanner = QRScannerViewController()
        scanner.onKey = { [weak self] key in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.finishPairing(hostName: hostName, key: key)
            }
        }
        scanner.onManualEntry = { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.presentManualEntry(hostName: hostName)
            }
        }
        scanner.modalPresentationStyle = .fullScreen
        presentSafely(scanner)
    }

    private func presentManualEntry(hostName: String) {
        let alert = UIAlertController(
            title: "手动输入配对密钥",
            message: "粘贴 Mac 上显示的密钥，或完整的 xdrscreen://pair?key=… 链接。",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "xdrscreen://pair?key=…"
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "配对", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            guard let key = PairingKey.decode(text) else {
                self?.showAlert(
                    title: "密钥格式不正确",
                    message: "需要 32 字节密钥：base64url 文本、64 位十六进制，或完整的配对链接。"
                )
                return
            }
            self?.finishPairing(hostName: hostName, key: key)
        })
        presentSafely(alert)
    }

    private func finishPairing(hostName: String, key: Data) {
        switch controller.pair(hostName: hostName, key: key) {
        case .success:
            showToast("配对密钥已保存，正在连接 \(hostName)…")
        case .failure(let error):
            showAlert(title: "无法保存配对密钥", message: error.localizedDescription)
        }
    }

    private func confirmForgetPairing() {
        let alert = UIAlertController(
            title: "清除配对密钥？",
            message: "这会从本机钥匙串删除密钥，需要重新扫描二维码才能连接。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            self?.controller.forgetPairing()
        })
        presentSafely(alert)
    }

    private func presentSheet(_ alert: UIAlertController, anchor: UIView?) {
        if let popover = alert.popoverPresentationController {
            if let anchor {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            } else {
                popover.sourceView = view
                popover.sourceRect = CGRect(
                    x: view.bounds.midX,
                    y: view.bounds.midY,
                    width: 1,
                    height: 1
                )
            }
            popover.permittedArrowDirections = .any
        }
        presentSafely(alert)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presentSafely(alert)
    }

    /// Presents without racing UIKit's dismissal animation.
    ///
    /// UIAlertAction handlers run while their own sheet is still visible or
    /// animating away, and a synchronous `present` in that window is rejected
    /// with "already presenting" (the user taps and nothing appears). This
    /// waits on the main queue for this controller's own presented sheet to
    /// clear, then presents.
    ///
    /// It never dismisses anything: if a modal this app did not just dismiss
    /// (for example the QR scanner) is still up, the retries stop and the new
    /// presentation is dropped rather than tearing down the user's window.
    private func presentSafely(_ controller: UIViewController, attempt: Int = 0) {
        guard presentedViewController != nil else {
            present(controller, animated: true)
            return
        }
        // ~0.8 s covers a sheet dismissal plus presentation animation.
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentSafely(controller, attempt: attempt + 1)
        }
    }

    // MARK: - Control bar actions

    private func setBarExpanded(_ expanded: Bool) {
        barExpanded = expanded
        autoCollapseWork?.cancel()
        autoCollapseWork = nil
        controlTab.isHidden = expanded || latest.phase != .streaming
        controlBar.isHidden = !(expanded && latest.phase == .streaming)
        updateBarContent()
        guard expanded, !touchView.isFirstResponder else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.touchView.isFirstResponder else { return }
            self.setBarExpanded(false)
        }
        autoCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    @objc private func collapseTapped() {
        setBarExpanded(false)
    }

    /// Target-bitrate presets. The protocol accepts 4–200 Mbps; the sheet
    /// offers the same practical steps as the Mac window.
    private static let bitrateChoices = [10, 20, 30, 50, 80, 120]

    @objc private func bitrateTapped() {
        let current = latest.preferredBitrateMbps
        let alert = UIAlertController(
            title: "目标码率",
            message: "选择后立即同步到 Mac；「跟随主机」使用 Mac 的画质档位。弱网时仍会自动降码率。",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: current == nil ? "✓ 跟随主机" : "跟随主机",
            style: .default
        ) { [weak self] _ in
            self?.controller.setPreferredBitrateMbps(nil)
        })
        for mbps in Self.bitrateChoices {
            alert.addAction(UIAlertAction(
                title: current == mbps ? "✓ \(mbps) Mbps" : "\(mbps) Mbps",
                style: .default
            ) { [weak self] _ in
                self?.controller.setPreferredBitrateMbps(mbps)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSheet(alert, anchor: bitrateButton)
    }

    @objc private func filesTapped() {
        let sheet = FileTransferViewController(service: fileTransfer)
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.modalPresentationStyle = .pageSheet
        navigation.overrideUserInterfaceStyle = .dark
        if let presentation = navigation.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        presentSafely(navigation)
    }

    @objc private func toggleKeyboard() {
        if touchView.isFirstResponder {
            _ = touchView.resignFirstResponder()
        } else {
            _ = touchView.becomeFirstResponder()
        }
        keyboardStateChanged(touchView.isFirstResponder)
    }

    private func keyboardStateChanged(_ active: Bool) {
        var config = keyboardButton.configuration
        config?.baseForegroundColor = active ? Palette.positive : Palette.primary
        keyboardButton.configuration = config
        if active {
            setBarExpanded(true)
            autoCollapseWork?.cancel()
            autoCollapseWork = nil
        }
    }

    @objc private func reconnectTapped() {
        controller.retryConnection()
        setBarExpanded(false)
    }

    @objc private func disconnectTapped() {
        touchView.releaseAllInput()
        controller.disconnect()
        setBarExpanded(false)
    }

    private func updateBarContent() {
        let streaming = latest.phase == .streaming
        switch latest.phase {
        case .failed:
            barDot.backgroundColor = Palette.negative
        case .reconnecting:
            barDot.backgroundColor = Palette.warning
        case .streaming:
            barDot.backgroundColor = Palette.positive
        default:
            barDot.backgroundColor = Palette.secondary
        }

        guard streaming, let stream = latest.stream else {
            barLabel.text = streaming ? "已连接 · 等待画面…" : statusTitle()
            return
        }
        var parts: [String] = [
            "\(stream.width)×\(stream.height)",
            stream.codec,
            stream.hdrText,
            "\(displayView.renderedFPS) fps"
        ]
        // Never imply an EDR picture when the compatibility decoder is used.
        if displayView.isUsingFallbackRenderer {
            parts.append("兼容渲染")
        }
        if latest.latencyMs > 0 {
            parts.append("\(latest.latencyMs) ms")
        }
        barLabel.text = parts.joined(separator: " · ")
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateBarContent()
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        toastLabel.text = text
        toastContainer.isHidden = false
        UIView.animate(withDuration: 0.16) {
            self.toastContainer.alpha = 1
        }
        toastHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.25, animations: {
                self.toastContainer.alpha = 0
            }, completion: { _ in
                self.toastContainer.isHidden = true
            })
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }
}

// MARK: - Drop to send

extension ClientViewController: UIDropInteractionDelegate {

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: canHandleDrop(session) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        guard !providers.isEmpty else { return }

        // Resolve every provider before queueing so files keep the order the
        // user dropped them in.
        var loaded = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                loaded[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let urls = loaded.compactMap { $0 }
            guard !urls.isEmpty else {
                self.showToast("拖入的内容不是文件。")
                return
            }
            // The service checks the authenticated session itself and reports
            // "尚未连接 Mac" through `lastError`, which the root view toasts.
            self.fileTransfer.sendFiles(at: urls)
            self.showToast(urls.count == 1
                           ? "正在发送 \(urls[0].lastPathComponent)…"
                           : "正在发送 \(urls.count) 个文件…")
        }
    }

    private func canHandleDrop(_ session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier])
    }
}

// MARK: - File transfer sheet

private final class FileTransferViewController: UIViewController,
                                               UITableViewDataSource,
                                               UITableViewDelegate,
                                               UIDocumentPickerDelegate {

    private let service: FileTransferService
    private var items: [FileTransferItem] = []
    private var cancellables = Set<AnyCancellable>()
    private var pickingDestination = false

    private let sendButton = UIButton(type: .system)
    private let destinationValueLabel = UILabel()
    private let chooseFolderButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let connectionLabel = UILabel()
    private let statusLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    init(service: FileTransferService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Palette.panel
        title = "文件传输"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )

        buildHeader()
        buildTable()
        bindService()
        apply(items: service.items)
        destinationChanged(path: service.destinationPath, custom: service.usesCustomDestination)
        connectionChanged(service.isConnected)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.contentInset.bottom = view.safeAreaInsets.bottom
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: Layout

    private func buildHeader() {
        var sendConfig = UIButton.Configuration.filled()
        sendConfig.title = "发送文件…"
        sendConfig.image = UIImage(systemName: "tray.and.arrow.up")
        sendConfig.imagePadding = 8
        sendConfig.baseForegroundColor = .black
        sendConfig.baseBackgroundColor = Palette.primary
        sendConfig.cornerStyle = .medium
        sendConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 15, weight: .semibold)
            return out
        }
        sendButton.configuration = sendConfig
        sendButton.addAction(UIAction { [weak self] _ in
            self?.presentSendPicker()
        }, for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let destinationTitle = UILabel()
        destinationTitle.text = "接收目录"
        destinationTitle.font = .systemFont(ofSize: 11, weight: .medium)
        destinationTitle.textColor = Palette.tertiary

        destinationValueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        destinationValueLabel.textColor = Palette.secondary
        destinationValueLabel.numberOfLines = 2
        destinationValueLabel.lineBreakMode = .byTruncatingMiddle

        configureSecondaryButton(chooseFolderButton, title: "选择文件夹…") { [weak self] in
            self?.presentDestinationPicker()
        }
        configureSecondaryButton(restoreButton, title: "恢复默认") { [weak self] in
            self?.service.restoreDefaultDestination()
        }

        let buttons = UIStackView(arrangedSubviews: [chooseFolderButton, restoreButton, UIView()])
        buttons.axis = .horizontal
        buttons.spacing = 8

        let destinationStack = UIStackView(arrangedSubviews: [
            destinationTitle, destinationValueLabel, buttons
        ])
        destinationStack.axis = .vertical
        destinationStack.spacing = 6
        destinationStack.translatesAutoresizingMaskIntoConstraints = false

        let destinationBox = UIView()
        destinationBox.translatesAutoresizingMaskIntoConstraints = false
        destinationBox.backgroundColor = UIColor(white: 1, alpha: 0.05)
        destinationBox.layer.cornerRadius = 10
        destinationBox.layer.cornerCurve = .continuous
        destinationBox.layer.borderWidth = 1 / UIScreen.main.scale
        destinationBox.layer.borderColor = Palette.stroke.cgColor
        destinationBox.addSubview(destinationStack)
        NSLayoutConstraint.activate([
            destinationStack.leadingAnchor.constraint(equalTo: destinationBox.leadingAnchor, constant: 12),
            destinationStack.trailingAnchor.constraint(equalTo: destinationBox.trailingAnchor, constant: -12),
            destinationStack.topAnchor.constraint(equalTo: destinationBox.topAnchor, constant: 10),
            destinationStack.bottomAnchor.constraint(equalTo: destinationBox.bottomAnchor, constant: -10)
        ])

        connectionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        connectionLabel.textColor = Palette.tertiary
        connectionLabel.numberOfLines = 0

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Palette.warning
        statusLabel.numberOfLines = 2
        statusLabel.isHidden = true

        let header = UIStackView(arrangedSubviews: [
            sendButton, destinationBox, connectionLabel, statusLabel
        ])
        header.axis = .vertical
        header.spacing = 10
        header.setCustomSpacing(6, after: destinationBox)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
        self.headerBottom = header.bottomAnchor
    }

    private var headerBottom: NSLayoutYAxisAnchor!

    private func configureSecondaryButton(_ button: UIButton,
                                          title: String,
                                          action: @escaping () -> Void) {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseForegroundColor = Palette.primary
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12, weight: .medium)
            return out
        }
        button.configuration = config
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func buildTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 1, alpha: 0.08)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.register(FileTransferCell.self, forCellReuseIdentifier: FileTransferCell.reuseIdentifier)
        view.addSubview(tableView)

        emptyLabel.text = "暂无传输。点按「发送文件…」或把文件拖入画面。"
        emptyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        emptyLabel.textColor = Palette.tertiary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerBottom, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 48),
            emptyLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    // MARK: Service observation

    private func bindService() {
        service.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.apply(items: items) }
            .store(in: &cancellables)

        service.$destinationPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                guard let self else { return }
                self.destinationChanged(path: path, custom: self.service.usesCustomDestination)
            }
            .store(in: &cancellables)

        service.$usesCustomDestination
            .receive(on: DispatchQueue.main)
            .sink { [weak self] custom in
                guard let self else { return }
                self.destinationChanged(path: self.service.destinationPath, custom: custom)
            }
            .store(in: &cancellables)

        service.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.connectionChanged(connected) }
            .store(in: &cancellables)

        service.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.statusLabel.text = message
                self.statusLabel.isHidden = message == nil
            }
            .store(in: &cancellables)
    }

    private func apply(items newItems: [FileTransferItem]) {
        let oldIDs = items.map(\.id)
        items = newItems
        emptyLabel.isHidden = !items.isEmpty

        if oldIDs != items.map(\.id) {
            tableView.reloadData()
            return
        }
        // Same rows, new bytes: update in place so an active drag-out and the
        // cancel buttons keep working while progress changes.
        for cell in tableView.visibleCells {
            guard let cell = cell as? FileTransferCell,
                  let indexPath = tableView.indexPath(for: cell),
                  indexPath.row < items.count else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func destinationChanged(path: String, custom: Bool) {
        destinationValueLabel.text = path
        restoreButton.isHidden = !custom
    }

    private func connectionChanged(_ connected: Bool) {
        connectionLabel.text = connected
            ? "已连接 Mac，可收发文件。"
            : "尚未连接 Mac。发送前请先连接；接收由 Mac 发起。"
        sendButton.isEnabled = connected
        sendButton.alpha = connected ? 1 : 0.5
    }

    // MARK: Pickers

    private func presentSendPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        pickingDestination = false
        present(picker, animated: true)
    }

    private func presentDestinationPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pickingDestination = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let destination = pickingDestination
        pickingDestination = false
        if destination {
            guard let url = urls.first else { return }
            service.setDestination(url)
        } else {
            service.sendFiles(at: urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickingDestination = false
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FileTransferCell.reuseIdentifier,
            for: indexPath
        ) as! FileTransferCell
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: FileTransferCell, at indexPath: IndexPath) {
        let item = items[indexPath.row]
        cell.configure(with: item)
        cell.onCancel = { [weak self] in
            self?.service.cancelTransfer(id: item.id)
        }
        cell.onShare = { [weak self, weak cell] in
            guard let self, let url = item.localURL, let cell else { return }
            self.presentShare(url: url, from: cell.shareButton)
        }
    }

    private func presentShare(url: URL, from anchor: UIView) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = .any
        }
        present(activity, animated: true)
    }
}

// MARK: - Transfer row

private final class FileTransferCell: UITableViewCell, UIDragInteractionDelegate {

    static let reuseIdentifier = "FileTransferCell"

    let shareButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let cancelButton = UIButton(type: .system)
    private var dragURL: URL?

    var onCancel: (() -> Void)?
    var onShare: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = Palette.primary
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = Palette.secondary
        detailLabel.numberOfLines = 2

        progressView.trackTintColor = UIColor(white: 1, alpha: 0.1)
        progressView.progressTintColor = Palette.positive
        progressView.layer.cornerRadius = 1.5
        progressView.clipsToBounds = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.heightAnchor.constraint(equalToConstant: 3).isActive = true

        configureIconButton(shareButton, systemName: "square.and.arrow.up")
        shareButton.accessibilityLabel = "分享"
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        configureIconButton(cancelButton, systemName: "xmark.circle")
        cancelButton.accessibilityLabel = "取消"
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, shareButton, cancelButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel, progressView])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        // Drag a finished received file out to Files or another app.
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        contentView.addInteraction(drag)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureIconButton(_ button: UIButton, systemName: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)
        config.baseForegroundColor = Palette.secondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    func configure(with item: FileTransferItem) {
        nameLabel.text = item.name
        detailLabel.text = "\(item.direction.title) · \(item.statusText)"
        progressView.progress = Float(item.progress)
        progressView.isHidden = false
        progressView.progressTintColor = {
            switch item.status {
            case .completed: return Palette.positive
            case .failed: return Palette.negative
            case .cancelled: return Palette.tertiary
            case .waiting, .transferring: return Palette.warning
            }
        }()
        detailLabel.textColor = item.status == .failed ? Palette.negative : Palette.secondary

        cancelButton.isHidden = !item.status.isActive
        let shareable = item.direction == .receive
            && item.status == .completed
            && item.localURL != nil
        shareButton.isHidden = !shareable
        dragURL = shareable ? item.localURL : nil
        accessibilityLabel = "\(item.direction.title) \(item.name)，\(item.statusText)"
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func shareTapped() {
        onShare?()
    }

    // MARK: UIDragInteractionDelegate

    func dragInteraction(_ interaction: UIDragInteraction,
                         itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let url = dragURL,
              let provider = NSItemProvider(contentsOf: url) else { return [] }
        return [UIDragItem(itemProvider: provider)]
    }
}

// MARK: - Pairing camera

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onKey: ((Data) -> Void)?
    var onManualEntry: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.xdrscreen.client.qr")
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let viewfinder = UIView()
    private let manualButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private var configured = false
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildOverlay()
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    deinit {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: UI

    private func buildOverlay() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        var closeConfig = UIButton.Configuration.plain()
        closeConfig.title = "关闭"
        closeConfig.baseForegroundColor = .white
        closeConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        closeConfig.background.backgroundColor = UIColor(white: 0, alpha: 0.45)
        closeConfig.background.cornerRadius = 15
        closeButton.configuration = closeConfig
        closeButton.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        view.addSubview(closeButton)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "扫描 Mac 上的配对二维码"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = "把 Mac 窗口中显示的二维码放入取景框。"
        messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = UIColor(white: 0.75, alpha: 1)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        view.addSubview(messageLabel)

        viewfinder.translatesAutoresizingMaskIntoConstraints = false
        viewfinder.layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        viewfinder.layer.borderWidth = 2
        viewfinder.layer.cornerRadius = 18
        viewfinder.layer.cornerCurve = .continuous
        viewfinder.backgroundColor = .clear
        viewfinder.isUserInteractionEnabled = false
        view.addSubview(viewfinder)

        var manualConfig = UIButton.Configuration.filled()
        manualConfig.title = "手动输入密钥"
        manualConfig.baseForegroundColor = .white
        manualConfig.baseBackgroundColor = UIColor(white: 1, alpha: 0.18)
        manualConfig.cornerStyle = .medium
        manualConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .medium)
            return out
        }
        manualButton.translatesAutoresizingMaskIntoConstraints = false
        manualButton.configuration = manualConfig
        manualButton.addAction(UIAction { [weak self] _ in
            self?.onManualEntry?()
        }, for: .touchUpInside)
        view.addSubview(manualButton)

        var settingsConfig = UIButton.Configuration.plain()
        settingsConfig.title = "打开设置"
        settingsConfig.baseForegroundColor = UIColor(white: 0.8, alpha: 1)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.configuration = settingsConfig
        settingsButton.isHidden = true
        settingsButton.addAction(UIAction { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }, for: .touchUpInside)
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 12),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            viewfinder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            viewfinder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            viewfinder.widthAnchor.constraint(equalToConstant: 260),
            viewfinder.heightAnchor.constraint(equalToConstant: 260),
            manualButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            manualButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            manualButton.heightAnchor.constraint(equalToConstant: 44),
            manualButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: manualButton.topAnchor, constant: -8)
        ])
    }

    private func installPreviewLayerIfNeeded() {
        guard previewLayer == nil else { return }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    // MARK: Camera

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.showCameraDenied()
                    }
                }
            }
        case .denied, .restricted:
            showCameraDenied()
        default:
            showCameraDenied()
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.configured else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.showUnavailable() }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            guard self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showUnavailable() }
                return
            }
            self.session.addInput(input)

            guard self.session.canAddOutput(self.metadataOutput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showUnavailable() }
                return
            }
            self.session.addOutput(self.metadataOutput)
            self.metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                self.metadataOutput.metadataObjectTypes = [.qr]
            } else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showUnavailable() }
                return
            }
            self.session.commitConfiguration()
            self.configured = true

            DispatchQueue.main.async { self.installPreviewLayerIfNeeded() }
            self.session.startRunning()
        }
    }

    private func stopSession() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func showCameraDenied() {
        messageLabel.text = "相机权限被拒绝。可以在“设置 › 隐私与安全性 › 相机”中允许 XDRScreen，或直接手动输入密钥。"
        settingsButton.isHidden = false
        viewfinder.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        manualButton.configuration?.baseBackgroundColor = UIColor(white: 1, alpha: 0.28)
    }

    private func showUnavailable() {
        messageLabel.text = "这台设备没有可用的相机。请手动输入 Mac 上显示的密钥。"
        settingsButton.isHidden = true
        viewfinder.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
    }

    // MARK: Metadata delegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  code.type == .qr,
                  let value = code.stringValue else { continue }
            guard let key = PairingKey.decode(value) else {
                messageLabel.text = "二维码不是有效的 XDRScreen 配对码。"
                return
            }
            delivered = true
            stopSession()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onKey?(key)
            return
        }
    }
}
