import CarbShared
import FirebaseAuth
import FirebaseCore

/// Gets a Firebase ID token for Siri requests.
///
/// App Intents in the Runner target run inside the app's process, so they can
/// use Firebase Auth directly. `getIDToken()` refreshes the token when it has
/// expired (ID tokens last one hour), which the old shared-token copy couldn't.
enum SiriAuth {
    static func idToken() async throws -> String {
        let user = await MainActor.run { () -> User? in
            // A background Siri launch may not start the Flutter engine, so
            // configure Firebase here if FlutterFire hasn't yet. FlutterFire
            // skips its own setup when a default app already exists.
            if FirebaseApp.app() == nil {
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
            throw IntentError.message("Couldn't reach CarpeCarb. Check your connection and try again.")
        }
    }
}
