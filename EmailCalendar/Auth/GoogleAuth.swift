#if os(macOS)
import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

public struct GoogleOAuthConfiguration: Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func fromBundle(_ bundle: Bundle = .main) throws -> Self {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              !clientID.isEmpty, !clientID.contains("$("), !clientID.hasPrefix("YOUR_") else {
            throw GoogleOAuthError.missingConfiguration
        }
        let secret = bundle.object(forInfoDictionaryKey: "GOOGLE_CLIENT_SECRET") as? String
        return Self(clientID: clientID, clientSecret: secret?.isEmpty == false && secret?.contains("$(") == false
                    && secret?.hasPrefix("YOUR_") == false ? secret : nil)
    }
}

public enum GoogleOAuthError: Error, LocalizedError, Sendable {
    case missingConfiguration, randomGenerationFailed, invalidState, missingCode, notSignedIn, busy, timedOut
    case authorization(String)
    case token(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Add your Google Desktop OAuth client ID to Config/Secrets.xcconfig, then rebuild the app."
        case .randomGenerationFailed: "Could not generate a secure sign-in challenge."
        case .invalidState: "The sign-in response did not match the request. Please try again."
        case .missingCode: "Google did not return a sign-in code."
        case .notSignedIn: "Sign in with Google to continue."
        case .busy: "A Google sign-in is already in progress."
        case .timedOut: "Google sign-in timed out. Please try again."
        case let .authorization(message): "Google sign-in: \(message)"
        case let .token(message): "Google authorization: \(message)"
        }
    }
}

@MainActor
public final class GoogleAuth: NSObject, ObservableObject, GoogleTokenProvider, ASWebAuthenticationPresentationContextProviding {
    @Published public private(set) var account: Account?
    @Published public private(set) var isSigningIn = false
    @Published public private(set) var restorationError: String?
    public var isSignedIn: Bool { account != nil && credentials?.refreshToken != nil }

    private let configuration: GoogleOAuthConfiguration?
    private let keychain: KeychainStore
    private let session: URLSession
    private var credentials: Credentials?
    private var webSession: ASWebAuthenticationSession?
    private var refreshTask: Task<String, any Error>?
    private var refreshTaskID: UUID?
    private var generation = UUID()

    public init(configuration: GoogleOAuthConfiguration? = nil, session: URLSession = .shared) {
        self.configuration = configuration ?? (try? GoogleOAuthConfiguration.fromBundle())
        self.session = session
        self.keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "app.emailcalendar").google-oauth")
        super.init()
        do {
            if let data = try keychain.read() {
                let restored = try JSONDecoder().decode(Credentials.self, from: data)
                // Credentials from another Desktop OAuth client cannot be refreshed by this build.
                if self.configuration?.clientID == restored.clientID {
                    credentials = restored
                    account = restored.account
                }
            }
        } catch { restorationError = error.localizedDescription }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    @discardableResult
    public func signIn() async throws -> Account {
        guard !isSigningIn else { throw GoogleOAuthError.busy }
        guard let configuration else { throw GoogleOAuthError.missingConfiguration }
        let signInGeneration = generation
        isSigningIn = true
        defer { isSigningIn = false; webSession = nil }
        let verifier = try Self.randomURLSafe(byteCount: 64)
        let state = try Self.randomURLSafe(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let server = LoopbackRedirectServer(expectedState: state)
        let redirectURL = try await server.start()
        var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]
        // ASWebAuthenticationSession's HTTPS callback API cannot match an HTTP loopback URL.
        // The real HTTP listener completes the flow; cancelling afterward closes the session.
        let browser = ASWebAuthenticationSession(url: authorization.url!, callbackURLScheme: nil) { _, error in
            if let error { Task { await server.cancel(error: error) } }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        webSession = browser
        guard browser.start() else {
            await server.cancel()
            throw GoogleOAuthError.authorization("The sign-in browser could not be opened.")
        }
        let callback: URL
        do { callback = try await server.waitForCallback() }
        catch { browser.cancel(); throw error }
        browser.cancel()
        guard let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GoogleOAuthError.missingCode
        }
        guard values.filter({ $0.name == "state" }).count == 1,
              values.first(where: { $0.name == "state" })?.value == state else { throw GoogleOAuthError.invalidState }
        if let error = values.first(where: { $0.name == "error" })?.value { throw GoogleOAuthError.authorization(error) }
        guard let code = values.first(where: { $0.name == "code" })?.value else { throw GoogleOAuthError.missingCode }
        let response = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURL.absoluteString,
            "code_verifier": verifier, "client_id": configuration.clientID
        ], configuration: configuration)
        try Self.verifyScopes(response.scope)
        guard let refreshToken = response.refresh_token else {
            throw GoogleOAuthError.token("Google did not issue an offline token. Remove the app's access in your Google account and sign in again.")
        }
        let profile = try await fetchMailProfile(accessToken: response.access_token)
        guard generation == signInGeneration else { throw CancellationError() }
        let account = Account(id: profile.emailAddress.lowercased(), email: profile.emailAddress)
        let credentials = Credentials(clientID: configuration.clientID, accessToken: response.access_token,
                                      refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(response.expires_in), account: account)
        try keychain.write(JSONEncoder().encode(credentials))
        self.credentials = credentials
        self.account = account
        restorationError = nil
        generation = UUID()
        return account
    }

    public func signOut() async throws {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        webSession?.cancel()
        webSession = nil
        try keychain.delete()
        credentials = nil
        account = nil
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credentials, let configuration else { throw GoogleOAuthError.notSignedIn }
        if !forceRefresh, credentials.expiresAt > Date().addingTimeInterval(60) { return credentials.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let currentGeneration = generation
        let taskID = UUID()
        let task = Task { @MainActor in
            guard let refreshToken = credentials.refreshToken else { throw GoogleOAuthError.notSignedIn }
            let response = try await self.tokenRequest([
                "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": configuration.clientID
            ], configuration: configuration)
            guard currentGeneration == self.generation else { throw CancellationError() }
            try Self.verifyScopes(response.scope)
            var updated = credentials
            updated.accessToken = response.access_token
            updated.expiresAt = Date().addingTimeInterval(response.expires_in)
            updated.refreshToken = response.refresh_token ?? refreshToken
            try self.keychain.write(JSONEncoder().encode(updated))
            self.credentials = updated
            return updated.accessToken
        }
        refreshTask = task
        refreshTaskID = taskID
        defer {
            if refreshTaskID == taskID { refreshTask = nil; refreshTaskID = nil }
        }
        do { return try await task.value }
        catch {
            if case GoogleOAuthError.token(let reason) = error, reason == "invalid_grant" {
                try? keychain.delete()
                self.credentials = nil
                account = nil
            }
            throw error
        }
    }

    private func tokenRequest(_ parameters: [String: String], configuration: GoogleOAuthConfiguration) async throws -> TokenResponse {
        var parameters = parameters
        if let secret = configuration.clientSecret { parameters["client_secret"] = secret }
        var body = URLComponents()
        body.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(TokenError.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GoogleOAuthError.token(reason)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchMailProfile(accessToken: String) async throws -> GoogleMailProfile {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleOAuthError.authorization("Could not read the signed-in Gmail account.")
        }
        return try JSONDecoder().decode(GoogleMailProfile.self, from: data)
    }

    private static let scopes = ["https://www.googleapis.com/auth/gmail.modify",
                                 "https://www.googleapis.com/auth/gmail.settings.basic",
                                 "https://www.googleapis.com/auth/calendar"]

    private static func verifyScopes(_ scope: String?) throws {
        // Token refresh responses may omit scope when the grants have not changed.
        guard let scope else { return }
        let granted = Set(scope.split(separator: " ").map(String.init))
        guard scopes.allSatisfy(granted.contains) else {
            throw GoogleOAuthError.authorization("Grant Gmail, Gmail settings, and Calendar access to use the app.")
        }
    }

    private static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw GoogleOAuthError.randomGenerationFailed
        }
        return Data(bytes).base64URL
    }

    private struct Credentials: Codable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var account: Account
    }
    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: TimeInterval
        var scope: String?
    }
    private struct TokenError: Decodable { var error: String }
}
#endif
