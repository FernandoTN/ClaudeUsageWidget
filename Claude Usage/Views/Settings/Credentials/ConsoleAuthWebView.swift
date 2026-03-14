//
//  ConsoleAuthWebView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-03-01.
//

import SwiftUI
import WebKit

// MARK: - Cookie Result

struct ConsoleCookieResult {
    let sessionKey: String
    let expiryDate: Date?
}

// MARK: - WKWebView Wrapper

struct ConsoleAuthWebView: NSViewRepresentable {
    let loginURL: URL
    let cookieDomain: String
    let onCookieFound: (ConsoleCookieResult) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Delete the sessionKey cookie so the user gets a fresh login,
        // but keep Google SSO cookies for the OAuth flow
        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                if cookie.domain.contains(self.cookieDomain) && cookie.name == "sessionKey" {
                    group.enter()
                    cookieStore.delete(cookie) { group.leave() }
                }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: self.loginURL))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieDomain: cookieDomain, onCookieFound: onCookieFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let cookieDomain: String
        let onCookieFound: (ConsoleCookieResult) -> Void
        private var foundCookie = false

        init(cookieDomain: String, onCookieFound: @escaping (ConsoleCookieResult) -> Void) {
            self.cookieDomain = cookieDomain
            self.onCookieFound = onCookieFound
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !foundCookie else { return }
            checkForSessionCookie(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Handle Google SSO popups by loading in the same webview
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// Called by the "Capture Session" button in ConsoleAuthSheet
        func extractCookie(from webView: WKWebView) {
            guard !foundCookie else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }

                for cookie in cookies {
                    if cookie.name == "sessionKey" && cookie.domain.contains(self.cookieDomain) {
                        self.foundCookie = true
                        let result = ConsoleCookieResult(
                            sessionKey: cookie.value,
                            expiryDate: cookie.expiresDate
                        )
                        DispatchQueue.main.async {
                            self.onCookieFound(result)
                        }
                        return
                    }
                }
            }
        }

        private func checkForSessionCookie(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }

                for cookie in cookies {
                    if cookie.name == "sessionKey" && cookie.domain.contains(self.cookieDomain) {
                        self.foundCookie = true
                        let result = ConsoleCookieResult(
                            sessionKey: cookie.value,
                            expiryDate: cookie.expiresDate
                        )
                        DispatchQueue.main.async {
                            self.onCookieFound(result)
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - Auth Sheet

struct ConsoleAuthSheet: View {
    let title: String
    let loginURL: URL
    let cookieDomain: String
    let onSuccess: (ConsoleCookieResult) -> Void
    let onCancel: () -> Void

    @State private var webView: WKWebView?
    @State private var coordinator: ConsoleAuthWebView.Coordinator?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // WebView
            ConsoleAuthWebViewWithCapture(
                loginURL: loginURL,
                cookieDomain: cookieDomain,
                onCookieFound: onSuccess,
                webViewRef: $webView,
                coordinatorRef: $coordinator
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar with capture button
            HStack {
                Text("Sign in above, then click Capture")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    if let webView = webView, let coordinator = coordinator {
                        coordinator.extractCookie(from: webView)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text("Capture Session")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 720)
    }
}

// MARK: - WebView with capture support

struct ConsoleAuthWebViewWithCapture: NSViewRepresentable {
    let loginURL: URL
    let cookieDomain: String
    let onCookieFound: (ConsoleCookieResult) -> Void
    @Binding var webViewRef: WKWebView?
    @Binding var coordinatorRef: ConsoleAuthWebView.Coordinator?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Store references for the capture button
        DispatchQueue.main.async {
            self.webViewRef = webView
            self.coordinatorRef = context.coordinator
        }

        // Delete the sessionKey cookie so the user gets a fresh login
        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                if cookie.domain.contains(self.cookieDomain) && cookie.name == "sessionKey" {
                    group.enter()
                    cookieStore.delete(cookie) { group.leave() }
                }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: self.loginURL))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> ConsoleAuthWebView.Coordinator {
        ConsoleAuthWebView.Coordinator(cookieDomain: cookieDomain, onCookieFound: onCookieFound)
    }
}
