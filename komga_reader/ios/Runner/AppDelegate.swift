import Flutter
import Network
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BeDeReaderScreen") {
      ScreenChannel.register(messenger: registrar.messenger())
    }
  }
}

/// The app's own platform channel (lib/screen.dart, "komga_reader/screen"), iOS side. What Android and Windows answer
/// that matters on an iPad: where the app keeps its files (downloads, eBook page counts), keeping the screen awake
/// while a book is open, the battery for the reader's clock, opening a link in the browser, and the way the screen is
/// up (the reader's rotation lock, Locked), the reader's screen brightness, mobile data or not (Downloads' Wi-Fi
/// only), and Save / Copy page (Photos, the clipboard) - as Android's (user, 2026-10-22). Full screen isn't asked for.
enum ScreenChannel {
  /// The level the reader set (nil: the screen follows the person's own), and their own level, to put back - iOS keeps
  /// an app's brightness after the app is left, Android doesn't.
  private static var ownBrightness: CGFloat?
  private static var theirBrightness: CGFloat?
  private static let paths = NWPathMonitor()
  private static var path: NWPath?

  static func register(messenger: FlutterBinaryMessenger) {
    paths.pathUpdateHandler = { p in path = p }
    paths.start(queue: DispatchQueue(label: "BeDeReader.network"))
    let center = NotificationCenter.default
    // the app left (another app, the home screen, locked): their own brightness back; back in the app: the reader's
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      if ownBrightness != nil, let theirs = theirBrightness { UIScreen.main.brightness = theirs }
    }
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      if let own = ownBrightness {
        theirBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = own
      }
    }
    let channel = FlutterMethodChannel(name: "komga_reader/screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "brightness":
        setBrightness((call.arguments as? NSNumber)?.doubleValue ?? -1)
        result(nil)
      case "getBrightness":
        result(Double(UIScreen.main.brightness))
      case "network":
        result(network())
      case "savePicture":
        savePicture(call.arguments, result)
      case "copyPicture":
        guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData,
          let image = UIImage(data: bytes.data)
        else {
          result(false)
          return
        }
        UIPasteboard.general.image = image
        result(true)
      case "storageDir":
        result(storageDir())
      case "keepOn":
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      case "battery":
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel  // 0...1, or -1 when unknown (the simulator)
        if level < 0 {
          result(nil)
          return
        }
        let charging = device.batteryState == .charging || device.batteryState == .full
        result(["level": Int((level * 100).rounded()), "charging": charging])
      case "openUrl":
        guard let text = call.arguments as? String, let url = URL(string: text) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
      case "fullscreen":
        result(false)  // an iPad app is always full screen
      case "currentWayUp":
        result(currentWayUp())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// -1: the person's own level back; else the reader's (0.01...1), their own kept to put back.
  private static func setBrightness(_ value: Double) {
    if value < 0 {
      if ownBrightness != nil, let theirs = theirBrightness { UIScreen.main.brightness = theirs }
      ownBrightness = nil
      theirBrightness = nil
      return
    }
    if ownBrightness == nil { theirBrightness = UIScreen.main.brightness }
    let level = CGFloat(min(max(value, 0.01), 1))
    ownBrightness = level
    UIScreen.main.brightness = level
  }

  /// "wifi" (or a cable), "cellular", "none", "other" - as Android's answer. Not known yet: "wifi" (better a download
  /// than a queue stuck for no reason).
  private static func network() -> String {
    guard let p = path else { return "wifi" }
    if p.status != .satisfied { return "none" }
    if p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet) { return "wifi" }
    if p.usesInterfaceType(.cellular) { return "cellular" }
    return "other"
  }

  /// Save page: into Photos (asked for once - adding only, nothing read). Answers where it went, or nil.
  private static func savePicture(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData else {
      result(nil)
      return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: bytes.data, options: nil)
      }) { saved, _ in
        DispatchQueue.main.async { result(saved ? "Photos" : nil) }
      }
    }
  }

  /// The way the screen is up now, named as Android's (lib/screen.dart, OrientationLock): portrait,
  /// reversePortrait, landscape (UIKit's landscapeLeft), reverseLandscape - or nil.
  private static func currentWayUp() -> String? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    switch scene?.interfaceOrientation {
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "reversePortrait"
    case .landscapeLeft: return "landscape"
    case .landscapeRight: return "reverseLandscape"
    default: return nil
    }
  }

  /// Application Support/BeDeReader: kept, backed up, not shown in the Files app, never cleared by the system (the
  /// temporary folder the Dart side falls back on is).
  private static func storageDir() -> String? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = base.appendingPathComponent("BeDeReader", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    return dir.path
  }
}
