// XboxApp — Xbox Cloud Gaming as a flat visionOS window.
//
// The Quest "Xbox" app (com.xbox.pwa) is Meta's PWA wrapper: no native code at
// all, just a shell that points the system browser at xbox.com/play. There is
// nothing in it for Klepton's translator to run — so the faithful port is the
// same shell built natively: one window, one WKWebView, the same START_URL.
// Controllers reach the page through WebKit's own Gamepad API support, which is
// how the PWA hears them on Quest too.
import SwiftUI
import WebKit
import GameController

@main
struct XboxApp: App {
    init() {
        // Pin the PROCESS locale to English. WKWebView derives Accept-Language
        // from the app's preferred languages, not the page's; on a device set
        // to Spanish every request said es-ES and xbox.com answered in kind.
        UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
    }
    var body: some Scene {
        WindowGroup {
            XboxWebView()
                .ignoresSafeArea()
                // The PWA's own manifest asks for landscape; a 16:10 window is
                // the same shape the Quest panel gives it.
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}

struct XboxWebView: UIViewRepresentable {
    // The wrapper's com.oculus.pwa.START_URL, verbatim.
    // en-US pinned in the path: xbox.com geo-routes a bare /play/ to the
    // visitor's country locale (es-ES from Spain) before headers even matter.
    static let startURL = URL(string: "https://www.xbox.com/en-US/play/")!

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Persistent store: the Microsoft sign-in must survive relaunches, the
        // way the PWA's browser profile does on Quest.
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Present the QUEST browser, not Safari: xbox.com/play keys its Quest
        // experience (controller-first UI, the layout the PWA gets) off the
        // "OculusBrowser" token, and detects Apple through navigator fields as
        // well as the UA. The user script below runs before any page script and
        // masks the ones WebKit exposes: platform reads Linux, touch reads
        // absent. navigator.userAgent itself follows customUserAgent for free.
        let spoof = WKUserScript(source: """
            (() => {
              const def = (o, k, v) => { try {
                Object.defineProperty(o, k, { get: () => v, configurable: true });
              } catch (e) {} };
              def(navigator, 'platform', 'Linux x86_64');
              def(navigator, 'maxTouchPoints', 0);
              def(navigator, 'vendor', 'Google Inc.');
              def(navigator, 'language', 'en-US');
              def(navigator, 'languages', ['en-US', 'en']);
              // The Quest path probes microphone devices for party chat. In a
              // WKWebView without mic entitlements navigator.mediaDevices does
              // not exist at all, and the app's probe then throws "undefined is
              // not an object" as a fullscreen error. Answer like a browser
              // with no devices attached instead: enumerate to an empty list,
              // refuse capture the way a denied permission would.
              if (!navigator.mediaDevices) {
                const md = {
                  enumerateDevices: () => Promise.resolve([]),
                  getUserMedia: () => Promise.reject(
                      new DOMException('Permission denied', 'NotAllowedError')),
                  getSupportedConstraints: () => ({}),
                  addEventListener: () => {}, removeEventListener: () => {},
                  ondevicechange: null,
                };
                def(navigator, 'mediaDevices', md);
              }
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(spoof)
        // A native GameController -> JS Gamepad API bridge. xbox.com/play's
        // controller-first (Quest) UI drives entirely off navigator.getGamepads()
        // and the gamepadconnected event; WebKit's own Gamepad API in a visionOS
        // WKWebView does not surface the paired controller to the page (it works
        // in Safari, not here), so the page saw no pad and every button was dead.
        // Rather than depend on that, synthesise the API from the live GCController
        // the app already receives (GCSupportsControllerUserInteraction=YES): the
        // Coordinator polls the extended gamepad and pushes W3C "standard"-mapping
        // state into window.__klPad below. The override yields to a real WebKit
        // gamepad if one ever appears, so this cannot double up.
        let padShim = WKUserScript(source: """
            (() => {
              const st = { b: new Array(17).fill(0), a: [0,0,0,0], t: 0, on: false };
              const pad = () => ({
                id: 'Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 02ea)',
                index: 0, connected: true, mapping: 'standard', timestamp: st.t,
                axes: st.a.slice(),
                buttons: st.b.map(v => ({ pressed: v > 0.5, touched: v > 0.1, value: v })),
                hapticActuators: [], vibrationActuator: null,
              });
              window.__klPad = (b, a) => {
                st.b = b; st.a = a; st.t = performance.now();
                if (!st.on) {
                  st.on = true;
                  try { window.dispatchEvent(new GamepadEvent('gamepadconnected',
                        { gamepad: pad() })); } catch (e) {}
                }
              };
              const orig = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : null;
              navigator.getGamepads = function () {
                const real = orig ? orig() : [];
                if (real && Array.prototype.some.call(real, g => g)) return real;
                return st.on ? [pad(), null, null, null] : [null, null, null, null];
              };
              if (navigator.webkitGetGamepads) navigator.webkitGetGamepads = navigator.getGamepads;
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(padShim)
        let web = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.attach(web)
        web.customUserAgent = "Mozilla/5.0 (X11; Linux x86_64; Quest 3) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) OculusBrowser/33.0.0.x.0 "
            + "SamsungBrowser/4.0 Chrome/126.0.0.0 VR Safari/537.36"
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: Self.startURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var web: WKWebView?
        private var timer: Timer?

        // Start polling the controller once the WebView exists. 60 Hz is the rate
        // getGamepads() is expected to be sampled at; each tick pushes the live
        // state into the page's __klPad shim. Pumped even with no controller (a
        // cheap no-op) so hot-plugging one mid-session just starts working.
        func attach(_ web: WKWebView) {
            self.web = web
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                         repeats: true) { [weak self] _ in self?.pump() }
        }

        private func pump() {
            guard let web = web,
                  let gp = GCController.controllers().lazy
                            .compactMap({ $0.extendedGamepad }).first else { return }
            func p(_ b: GCControllerButtonInput?) -> Float { (b?.isPressed ?? false) ? 1 : 0 }
            func v(_ b: GCControllerButtonInput?) -> Float { b?.value ?? 0 }
            // W3C "standard" mapping order — what xbox.com/play reads by index.
            let b: [Float] = [
                p(gp.buttonA), p(gp.buttonB), p(gp.buttonX), p(gp.buttonY),
                p(gp.leftShoulder), p(gp.rightShoulder),
                v(gp.leftTrigger), v(gp.rightTrigger),
                p(gp.buttonOptions), p(gp.buttonMenu),
                p(gp.leftThumbstickButton), p(gp.rightThumbstickButton),
                p(gp.dpad.up), p(gp.dpad.down), p(gp.dpad.left), p(gp.dpad.right),
                p(gp.buttonHome),
            ]
            // Standard axes are +right/+DOWN; GCController thumbsticks are +up, so
            // the Y axes are negated.
            let a: [Float] = [
                gp.leftThumbstick.xAxis.value, -gp.leftThumbstick.yAxis.value,
                gp.rightThumbstick.xAxis.value, -gp.rightThumbstick.yAxis.value,
            ]
            let bs = b.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let axs = a.map { String(format: "%.4f", $0) }.joined(separator: ",")
            web.evaluateJavaScript("window.__klPad&&window.__klPad([\(bs)],[\(axs)])",
                                   completionHandler: nil)
        }

        // The Microsoft login flow opens target=_blank windows. There is no
        // second window here; load them in place, which is what the PWA's
        // single-activity browser does with them as well.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
