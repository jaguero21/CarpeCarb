import Flutter
import UIKit
import CarbShared
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudSyncChannel: CloudSyncChannel?
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
  }
  
  override func applicationWillResignActive(_ application: UIApplication) {
    logger.info("📴 Application will resign active")
    super.applicationWillResignActive(application)
  }
  
  override func applicationDidEnterBackground(_ application: UIApplication) {
    logger.info("⏸️  Application entered background")
    super.applicationDidEnterBackground(application)
  }
  
  override func applicationWillEnterForeground(_ application: UIApplication) {
    logger.info("▶️  Application will enter foreground")
    super.applicationWillEnterForeground(application)
  }
  
  override func applicationDidBecomeActive(_ application: UIApplication) {
    logger.info("✅ Application became active")
    super.applicationDidBecomeActive(application)
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

