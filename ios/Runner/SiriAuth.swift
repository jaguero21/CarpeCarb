import CarbShared
import FirebaseAuth
import FirebaseCore
import os.log

/// Gets a Firebase ID token for Siri requests.
///
/// App Intents in the Runner target run inside the app's process, so they can
/// use Firebase Auth directly. `getIDToken()` refreshes the token when it has
/// expired (ID tokens last one hour), which the old shared-token copy couldn't.
enum SiriAuth {
    private static let logger = Logger(subsystem: "com.carpecarb", category: "SiriAuth")

    /// Errors after which Firebase signs the user out (`User.signOutIfTokenIsInvalid`
    /// in the FirebaseAuth pod), so Siri can't recover until the app signs in again.
    private static let signedOutCodes: Set<AuthErrorCode> = [
        .userNotFound, .userDisabled, .invalidUserToken, .userTokenExpired,
    ]

    static func idToken() async throws -> String {
        let user = await MainActor.run { () -> User? in
            // A background Siri launch may not start the Flutter engine, so
            // configure Firebase here if FlutterFire hasn't yet. FlutterFire
            // skips its own setup when a default app already exists.
            if FirebaseApp.app() == nil {
                // This reads GoogleService-Info.plist. Dart's
                // `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
                // (lib/main.dart) then reuses this default app only if its options
                // match lib/firebase_options.dart, so regenerate both together.
                FirebaseApp.configure()
            }
            return Auth.auth().currentUser
        }
        guard let user else {
            throw IntentError.message("Open CarpeCarb once to finish setting up Siri.")
        }
        do {
            return try await user.getIDToken()
        } catch {
            let nsError = error as NSError
            logger.error("❌ getIDToken failed (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)): \(nsError.localizedDescription)")
            throw IntentError.message(message(for: nsError))
        }
    }

    /// What Siri says when `getIDToken()` fails.
    private static func message(for error: NSError) -> String {
        if error.domain == AuthErrors.domain,
           let code = AuthErrorCode(rawValue: error.code),
           signedOutCodes.contains(code) {
            return "Open CarpeCarb once to finish setting up Siri."
        }
        return "Couldn't reach CarpeCarb. Check your connection and try again."
    }
}
