import Foundation

/// Built-in privacy rules: contexts that must never be captured.
enum ScreenExclusions {
    /// Bundle ids that are never captured: password managers, messengers, banking and finance apps.
    static let bundleIDs: Set<String> = [
        // Password managers
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron",
        "com.lastpass.LastPass",
        "com.nordpass.macos.NordPass",
        "com.keepersecurity.passwordmanager",
        "com.roboform.RoboForm",
        // Messengers
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "ch.threema.threema-desktop",
        "com.facebook.archon",
        "com.facebook.archon.developerID",
        "im.riot.app",
        "com.wire.wire",
        // Banking and finance desktop apps
        "com.moneymoney-app.retail",
        "com.moneymoney-app.ApplicationTrial",
        "de.starfinanz.StarMoney",
        "de.starfinanz.starmoney.mac",
        "de.subsembly.banking4",
        "com.banktivity.Banktivity",
        "com.iggsoftware.banktivity",
        "com.iggsoftware.banktivity7",
        "com.iggsoftware.banktivity8",
        "com.moneywiz.mac",
        "com.moneywiz.personalfinance",
        "com.quicken.Quicken",
        "com.intuit.quicken",
        "com.thirdiron.finanzblick",
        "de.buhl.finanzblick",
        "com.ynab.YNAB",
        "com.ledger.live",
        "com.electron.ledger-live-desktop",
        "io.trezor.TrezorSuite",
        "com.exodus.Exodus",
        "com.coinbase.wallet",
    ]

    /// Banking and payment domains. Matched against the domain and all its subdomains.
    static let domains: [String] = [
        "paypal.com", "paypal.me", "stripe.com", "wise.com", "klarna.com",
        "n26.com", "revolut.com", "qonto.com", "bunq.com", "vivid.money", "tomorrow.one",
        "sparkasse.de", "dkb.de", "comdirect.de", "ing.de", "commerzbank.de",
        "deutsche-bank.de", "db.com", "consorsbank.de", "postbank.de", "hypovereinsbank.de",
        "volksbank.de", "vr.de", "targobank.de", "santander.de", "norisbank.de",
        "1822direkt.de", "ing.com", "trade-republic.com", "traderepublic.com",
        "scalable.capital", "flatex.de", "smartbroker.de", "finanzen.net",
        "chase.com", "wellsfargo.com", "bankofamerica.com", "citi.com", "capitalone.com",
        "americanexpress.com", "amex.com", "schwab.com", "fidelity.com", "vanguard.com",
        "barclays.co.uk", "hsbc.com", "lloydsbank.com", "monzo.com", "starlingbank.com",
        "ubs.com", "credit-suisse.com", "raiffeisen.ch", "postfinance.ch", "erstebank.at",
        "george.sparkasse.at", "coinbase.com", "kraken.com", "binance.com",
        "elster.de", "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com",
        "login.live.com", "id.atlassian.com", "auth0.com", "okta.com",
    ]

    /// Path fragments that mark login and credential pages.
    static let sensitivePathFragments: [String] = [
        "/login", "/log-in", "/signin", "/sign-in", "/auth", "/oauth", "/sso",
        "/password", "/2fa", "/mfa", "/otp", "/verify",
    ]

    /// Window title fragments that mark private browsing windows.
    static let privateTitleFragments: [String] = [
        "private browsing", "incognito", "privates surfen", "inkognito", "inprivate",
    ]

    static func isExcluded(_ ctx: WindowContext, userBundleIDs: [String]) -> Bool {
        if ctx.isPrivateWindow { return true }
        if bundleIDs.contains(ctx.bundleID) { return true }
        let bid = ctx.bundleID.lowercased()
        if userBundleIDs.contains(where: { $0.lowercased() == bid }) { return true }
        if bid.contains("bank") || bid.contains("password") { return true }

        let title = ctx.windowTitle.lowercased()
        if privateTitleFragments.contains(where: { title.contains($0) }) { return true }

        if let host = normalizedHost(ctx) {
            if host.contains("bank") { return true }
            if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        }
        if let path = normalizedPath(ctx) {
            if sensitivePathFragments.contains(where: { path.contains($0) }) { return true }
        }
        return false
    }

    private static func normalizedHost(_ ctx: WindowContext) -> String? {
        var host = ctx.domain
        if host == nil, let raw = ctx.url, let comps = URLComponents(string: raw) { host = comps.host }
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private static func normalizedPath(_ ctx: WindowContext) -> String? {
        var path = ctx.urlPath
        if path == nil, let raw = ctx.url, let comps = URLComponents(string: raw) { path = comps.path }
        guard let p = path?.lowercased(), !p.isEmpty else { return nil }
        return p
    }
}
