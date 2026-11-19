import SwiftUI
import WebKit
import UIKit

/// WKWebView 容器：加载打包进 App 的 index.html，
/// 并通过注入脚本把 navigator.geolocation / deviceorientation 桥接到原生。
struct WebView: UIViewRepresentable {

    let bridge: LocationBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        /* 【重要】这里曾经用 KVC 写 private key：
         *   config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
         * WKPreferences 并没有公开这两个属性，靠 KVC 落到私有 ivar 上才能生效。
         * 一旦系统版本变化（该 ivar 被移除/改名），KVC 会抛 NSUnknownKeyException，
         * 而这是 ObjC 异常，Swift 的 do/catch 拦不住 —— 表现为「点开图标立刻闪退」。
         * 页面只从 https CDN 拉一个 script，本地读取由 loadFileURL(_:allowingReadAccessTo:)
         * 授权，不需要这两个私有开关，因此彻底移除。 */
        config.userContentController.add(context.coordinator, name: "geo")
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeShim,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)
        if #available(iOS 16.4, *) {
            webView.isInspectable = true   // Safari 远程调试
        }

        bridge.attach(webView)

        // 优先取 App.app/web/index.html（工程里 web 是 folder reference）；
        // 万一被当成普通文件组打进根目录，第二行兜底，避免白屏
        let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
        if let htmlURL = htmlURL {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h1 style='font-family:-apple-system;padding:24px'>web/index.html 未打包进 App</h1>",
                                   baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - 协调器

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let bridge: LocationBridge

        init(bridge: LocationBridge) {
            self.bridge = bridge
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "geo",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            let id = (body["id"] as? NSNumber)?.intValue ?? 0
            bridge.handle(action: action, id: id)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            print("[WebView] 加载失败:", error.localizedDescription)
        }
    }

    // MARK: - 注入脚本（页面脚本执行前运行）

    /// 作用有三个：
    /// 1. 让页面认为自己处于安全上下文（file:// 在 WebKit 里不算 secure context，
    ///    页面里有 `if (!window.isSecureContext)` 的判断会直接拦掉定位）；
    /// 2. 用原生桥替换 navigator.geolocation —— WKWebView 自带的 Web 定位在
    ///    无网络辅助定位时经常直接超时，原生 CoreLocation 更可靠；
    /// 3. 用原生磁力计数据伪造 deviceorientation 事件，带 webkitCompassHeading 字段，
    ///    正好命中页面中"iOS 分支"的取值逻辑，罗盘无需改动页面代码即可工作。
    private static let bridgeShim = #"""
    (function () {
      try {
        Object.defineProperty(window, 'isSecureContext', {
          get: function () { return true; },
          configurable: true
        });
      } catch (e) {}

      try {
        if (window.DeviceOrientationEvent) {
          window.DeviceOrientationEvent.requestPermission = function () {
            return Promise.resolve('granted');
          };
        }
      } catch (e) {}

      var callbacks = {};
      var seq = 0;

      function post(msg) {
        try { window.webkit.messageHandlers.geo.postMessage(msg); } catch (e) {}
      }

      var shim = {
        getCurrentPosition: function (ok, err, opts) {
          var id = ++seq;
          callbacks[id] = { ok: ok, err: err, once: true };
          post({ action: 'once', id: id });
          setTimeout(function () {
            if (callbacks[id]) {
              var cb = callbacks[id];
              delete callbacks[id];
              if (cb.err) { try { cb.err({ code: 3, message: 'timeout' }); } catch (e) {} }
            }
          }, 25000);
        },
        watchPosition: function (ok, err) {
          var id = ++seq;
          callbacks[id] = { ok: ok, err: err, once: false };
          post({ action: 'watch', id: id });
          return id;
        },
        clearWatch: function (id) {
          delete callbacks[id];
          post({ action: 'stop', id: id });
        }
      };

      try {
        Object.defineProperty(navigator, 'geolocation', { value: shim, configurable: true });
      } catch (e) {
        try { navigator.geolocation = shim; } catch (e2) {}
      }

      window.__nativeLocation = function (id, lat, lng, acc, heading, speed) {
        var cb = callbacks[id];
        if (!cb) return;
        var payload = {
          coords: {
            latitude: lat,
            longitude: lng,
            accuracy: acc,
            altitude: null,
            altitudeAccuracy: null,
            heading: (heading === null || heading === undefined || heading < 0) ? null : heading,
            speed: (speed === null || speed === undefined || speed < 0) ? null : speed
          },
          timestamp: Date.now()
        };
        try { cb.ok(payload); } catch (e) {}
        if (cb.once) delete callbacks[id];
      };

      window.__nativeError = function (id, code, message) {
        var cb = callbacks[id];
        if (!cb) return;
        try { if (cb.err) cb.err({ code: code, message: message }); } catch (e) {}
        if (cb.once) delete callbacks[id];
      };

      window.__nativeHeading = function (h) {
        try {
          var evt = new Event('deviceorientation');
          Object.defineProperty(evt, 'webkitCompassHeading', { value: h });
          Object.defineProperty(evt, 'alpha', { value: (360 - h) % 360 });
          Object.defineProperty(evt, 'beta', { value: 90 });
          Object.defineProperty(evt, 'gamma', { value: 0 });
          window.dispatchEvent(evt);
        } catch (e) {}
      };
    })();
    """#
}
