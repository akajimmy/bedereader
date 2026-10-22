import Flutter
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
/// up (the reader's rotation lock, Locked). The rest (full screen, network type, saving pictures) isn't asked for on
/// iOS, or falls back on the Dart side.
enum ScreenChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "komga_reader/screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
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
