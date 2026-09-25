import Flutter
import UIKit
import CarbShared
import os.log

@main
// `@preconcurrency` on the conformance: FlutterAppDelegate is main-actor
// isolated (it is a UIKit delegate), while Flutter's protocol is not annotated,
// so Swift 6 sees the conformance crossing an isolation boundary. The protocol's
// callbacks arrive on the main thread in practice.
@objc class AppDelegate: FlutterAppDelegate, @preconcurrency FlutterImplicitEngineDelegate {
  private var cloudSyncChannel: CloudSyncChannel?
  private var siriBufferChannel: SiriBufferChannel?
  private let logger = Logger(subsystem: "com.carpecarb", category: "AppDelegate")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    logger.info("🚀 Application launching")

    // Siri now gets its own fresh Firebase token (SiriAuth.swift). Remove the
    // copy older builds kept in App Group UserDefaults (plain text) and the
    // Keychain so it doesn't linger on updated devices.
    UserDefaults(suiteName: CarbDataStore.appGroupID)?.removeObject(forKey: "firebaseIdToken")
    KeychainHelper.delete(forKey: "firebaseIdToken")
    
    // Log launch options if present
    if let options = launchOptions {
      logger.debug("Launch options: \(options.keys.map { $0.rawValue }.joined(separator: ", "))")
    }
    
    observeLifecycle()

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    
    if result {
      logger.info("✓ Application launched successfully")
    } else {
      logger.error("❌ Application failed to launch")
    }
    
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    logger.info("🔧 Initializing implicit Flutter engine")
    
    // Register generated plugins
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    logger.debug("✓ Generated plugins registered")
    
    // Register our custom method channel
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CloudSyncChannel") else {
      logger.error("❌ Failed to get plugin registrar for CloudSyncChannel")
      return
    }
    
    logger.debug("✓ Plugin registrar obtained for CloudSyncChannel")
    
    cloudSyncChannel = CloudSyncChannel(messenger: registrar.messenger())
    logger.info("✓ CloudSyncChannel registered successfully")

    siriBufferChannel = SiriBufferChannel(messenger: registrar.messenger())
    logger.info("✓ SiriBufferChannel registered successfully")
  }
  
  /// Logs the lifecycle transitions iOS 26 deprecated as delegate overrides.
  ///
  /// The notifications are the replacement Apple's deprecation names. The
  /// overrides only logged and called `super`, so FlutterAppDelegate's own
  /// handling is untouched. The closures capture just the `Sendable` logger:
  /// they are nonisolated, and reaching main-actor state from one is the same
  /// runtime trap that crashed iCloud sync in #49.
  private func observeLifecycle() {
    let logger = self.logger
    let center = NotificationCenter.default
    center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      logger.info("📴 Application will resign active")
    }
    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      logger.info("▶️  Application will enter foreground")
    }
    center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      logger.info("✅ Application became active")
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    logger.info("⏸️  Application entered background")
    super.applicationDidEnterBackground(application)
  }
  
  override func applicationWillTerminate(_ application: UIApplication) {
    logger.info("🛑 Application will terminate")
    
    // Log if we're still observing (potential issue)
    if cloudSyncChannel != nil {
      logger.debug("CloudSyncChannel still exists at termination")
    }
    
    super.applicationWillTerminate(application)
  }
}
// MARK: - Logging Guide

/*
 AppDelegate Logging:
 
 🚀 info - App launch
 🔧 info - Engine initialization
 ✓  info/debug - Success operations
 ❌ error - Failures
 📴 info - Resign active
 ⏸️  info - Background
 ▶️  info - Foreground
 ✅ info - Became active
 🛑 info - Termination
 
 View logs:
 Console filter: category:AppDelegate
 */

