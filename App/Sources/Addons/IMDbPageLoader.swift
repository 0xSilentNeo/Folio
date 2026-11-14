import WebKit

/// Loads an IMDb page in a hidden WebKit view when plain HTTP is answered
/// with the AWS WAF JavaScript challenge (HTTP 202, ~2 KB). WebKit runs the
/// challenge, IMDb then serves the real page; we pull the embedded JSON out
/// of the DOM and copy the WAF token cookie to the shared cookie store so
/// later plain requests pass. Loads are serialised through one web view.
/// Images, fonts, styles and every script except the challenge's are blocked
/// by a content rule list, so a page costs a few hundred kilobytes.
@MainActor
final class IMDbPageLoader: NSObject, WKNavigationDelegate {
    static let shared = IMDbPageLoader()

    /// WebKit's user agent on this device; plain requests use the same one so
    /// the WAF token (which is bound to the client) stays valid.
    private(set) var userAgent: String? = UserDefaults.standard.string(forKey: "imdbWebUA")

    private var webView: WKWebView?
    private var rulesReady = false
    /// The content rules still compiling (1.30.4): the first page waits for
    /// them, 2 s at most. It loaded at once, with every image, font and script.
    private var rulesPending = false
    private struct Job { var id = UUID(); let url: URL; let continuation: CheckedContinuation<String?, Never> }
    private var queue: [Job] = []
    private var current: Job?
    private var navigations = 0
    private var timeout: DispatchWorkItem?

    private static let rules = """
    [
      {"trigger":{"url-filter":".*","resource-type":["image","media","font","style-sheet","svg-document","popup","ping"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","resource-type":["script"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"awswaf"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"challenge"},"action":{"type":"ignore-previous-rules"}}
    ]
    """

    private static let extractJS = """
    (function(){
      var n = document.getElementById('__NEXT_DATA__');
      var ld = Array.prototype.map.call(document.querySelectorAll('script[type="application/ld+json"]'), function(s){ return s.textContent; });
      var waf = !!document.querySelector('script[src*="awswaf"]') || !!document.querySelector('script[src*="challenge"]');
      return { next: n ? n.textContent : null, ld: ld, waf: waf, ua: navigator.userAgent, len: document.documentElement.outerHTML.length, title: document.title };
    })()
    """

    func load(_ url: URL) async -> String? {
        // A caller that goes away (another genre, a page closed, the next
        // search letter) takes its page out of the queue (1.26.0): until
        // then each waited its turn, up to 25 s, ahead of newer ones.
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Job(id: id, url: url, continuation: c))
                pump()
            }
        } onCancel: {
            Task { @MainActor in IMDbPageLoader.shared.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let i = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: i).continuation.resume(returning: nil)
        } else if current?.id == id {
            dlog("imdb", "webkit load given up by its caller")
            finish(nil)
        }
    }

    /// Makes sure `userAgent` is known (first use creates the web view).
    func ensureUserAgent() async {
        if userAgent != nil { return }
        let wv = makeWebView()
        let ua = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            wv.evaluateJavaScript("navigator.userAgent") { r, _ in c.resume(returning: r as? String) }
        }
        if let ua { userAgent = ua; UserDefaults.standard.set(ua, forKey: "imdbWebUA") }
    }

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        wv.navigationDelegate = self
        wv.isHidden = true
        webView = wv
        rulesPending = true
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "imdb-lite", encodedContentRuleList: Self.rules) { [weak self] list, error in
            Task { @MainActor in
                if let list { cfg.userContentController.add(list); self?.rulesReady = true }
                else { dlog("imdb/error", "content rules: \(error?.localizedDescription ?? "?")") }
                self?.rulesDone()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.rulesPending else { return }
            dlog("imdb", "content rules not ready after 2 s: loading without them")
            self.rulesDone()
        }
        return wv
    }

    private func rulesDone() {
        guard rulesPending else { return }
        rulesPending = false
        pump()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        _ = makeWebView()
        // Waits for the rules (rulesDone pumps again); the page stays queued,
        // so its caller can still give it up.
        guard !rulesPending else { return }
        let job = queue.removeFirst()
        current = job
        navigations = 0
        let wv = makeWebView()
        dlog("imdb", "webkit load \(job.url.path)")
        var req = URLRequest(url: job.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        // Same language as the plain requests; without it IMDb picked the page
        // language itself and episode titles came back in the original language.
        req.setValue(IMDbSource.language + ",en;q=0.8", forHTTPHeaderField: "Accept-Language")
        wv.load(req)
        let t = DispatchWorkItem { [weak self] in
            dlog("imdb/error", "webkit timeout for \(job.url.path)")
            self?.finish(nil)
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: t)
    }

    private func finish(_ html: String?) {
        timeout?.cancel(); timeout = nil
        webView?.stopLoading()
        let job = current
        current = nil
        job?.continuation.resume(returning: html)
        // Nothing queued: drop the page so the hidden web view sits idle.
        if queue.isEmpty { webView?.loadHTMLString("", baseURL: nil) }
        pump()
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        guard let job = current?.id else { return }
        navigations += 1
        wv.evaluateJavaScript(Self.extractJS) { [weak self] result, _ in
            Task { @MainActor in self?.handle(result as? [String: Any], wv, job: job) }
        }
    }

    private func handle(_ r: [String: Any]?, _ wv: WKWebView, job: UUID) {
        // Still the page this was read for (1.30.2): given up or timed out
        // meanwhile, its data went to the next page's caller.
        guard current?.id == job else { return }
        if let ua = r?["ua"] as? String, ua != userAgent { userAgent = ua; UserDefaults.standard.set(ua, forKey: "imdbWebUA") }
        let next = r?["next"] as? String
        let ld = (r?["ld"] as? [String]) ?? []
        if next == nil && ld.isEmpty {
            // Challenge page (or an empty shell): the challenge script reloads
            // the page on its own once it has a token; wait for that.
            let waf = (r?["waf"] as? Bool) ?? false
            dlog("imdb", "webkit nav \(navigations): no data yet (waf=\(waf), \(r?["len"] ?? 0) chars)")
            if navigations >= 4 { finish(nil) }
            return
        }
        var html = ""
        if let next { html += "<script id=\"__NEXT_DATA__\" type=\"application/json\">\(next)</script>\n" }
        for block in ld { html += "<script type=\"application/ld+json\">\(block)</script>\n" }
        dlog("imdb", "webkit ok after \(navigations) nav(s): next=\(next?.count ?? 0) ld=\(ld.count)")
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for c in cookies where c.domain.hasSuffix("imdb.com") { HTTPCookieStorage.shared.setCookie(c) }
        }
        finish(html)
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A load stopped on purpose (a timeout, the next page) says so late:
        // it mustn't end the page now loading (review, 9 Nov).
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard current != nil else { return }
        dlog("imdb/error", "webkit failed: \(error.localizedDescription)")
        finish(nil)
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        dlog("imdb/error", "webkit failed early: \(error.localizedDescription)")
        finish(nil)
    }
}
