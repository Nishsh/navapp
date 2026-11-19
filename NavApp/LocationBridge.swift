import Foundation
import CoreLocation
import WebKit

/// 原生定位 / 罗盘桥：替代 WKWebView 自带的 Web 定位
///
/// 页面里的 `navigator.geolocation` 和 `deviceorientation` 已被注入脚本接管，
/// 这里负责用 CoreLocation 取真实数据，再回灌给页面：
///   - 位置 → window.__nativeLocation(id, lat, lng, accuracy, heading, speed)
///   - 罗盘 → window.__nativeHeading(degrees)（以 webkitCompassHeading 形式派发事件）
final class LocationBridge: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private weak var webView: WKWebView?

    /// id → 是否一次性请求（getCurrentPosition 为 true，watchPosition 为 false）
    private var watchers: [Int: Bool] = [:]
    private var lastLocation: CLLocation?
    private var lastHeading: CLHeading?

    private var updatingLocation = false
    private var updatingHeading = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    // MARK: - 对外接口

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// App 启动时先要一次权限，页面里的定位请求随后就不会被系统打断
    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 处理来自 JS 的 geo 消息
    func handle(action: String, id: Int) {
        switch action {
        case "once":
            watchers[id] = true
            ensureStarted()
            if let location = lastLocation { deliver(location, to: id) }
            checkAuthorization(for: id)

        case "watch":
            watchers[id] = false
            ensureStarted()
            if let location = lastLocation { deliver(location, to: id) }
            checkAuthorization(for: id)

        case "stop":
            watchers.removeValue(forKey: id)
            if watchers.isEmpty { stopUpdates() }

        default:
            break
        }
    }

    // MARK: - 采集控制

    private func ensureStarted() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        default:
            break
        }
    }

    private func startUpdates() {
        if !updatingLocation {
            manager.startUpdatingLocation()
            updatingLocation = true
        }
        if !updatingHeading, CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
            updatingHeading = true
        }
    }

    private func stopUpdates() {
        if updatingLocation {
            manager.stopUpdatingLocation()
            updatingLocation = false
        }
        if updatingHeading {
            manager.stopUpdatingHeading()
            updatingHeading = false
        }
    }

    private func checkAuthorization(for id: Int) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            emitError(id: id, code: 1, message: "定位权限被拒绝，请到 设置 → 隐私 → 定位服务 中允许")
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !watchers.isEmpty { startUpdates() }
        case .denied, .restricted:
            for id in Array(watchers.keys) {
                emitError(id: id, code: 1, message: "定位权限被拒绝")
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        // 快照遍历：deliver 内部可能移除 once 条目，直接遍历字典会触发
        // "Mutation during enumeration" 崩溃
        for id in Array(watchers.keys) { deliver(location, to: id) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError else { return }
        // 瞬时定位失败不打断页面：页面自身对 code=3 有 3 次容忍逻辑
        let code: Int = (clError.code == .denied) ? 1 : 3
        for id in Array(watchers.keys) { emitError(id: id, code: code, message: clError.localizedDescription) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lastHeading = newHeading
        // 优先真北；不可用时退回磁北（页面的 COMPASS_OFFSET 就是为磁偏角预留的）
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard degrees >= 0 else { return }
        evaluate("window.__nativeHeading(\(String(format: "%.1f", degrees)));")
    }

    // MARK: - 回灌 JS

    private func deliver(_ location: CLLocation, to id: Int) {
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let acc = max(location.horizontalAccuracy, 0)

        // 页面约定：heading / speed 为负或无效时传 null，交由 JS 端降级到罗盘
        let heading = location.course >= 0 ? String(format: "%.1f", location.course) : "null"
        let speed = location.speed >= 0 ? String(format: "%.2f", location.speed) : "null"

        let js = String(
            format: "window.__nativeLocation(%d, %.8f, %.8f, %.1f, %@, %@);",
            id, lat, lng, acc, heading, speed
        )
        evaluate(js)

        if watchers[id] == true {
            watchers.removeValue(forKey: id)
            if watchers.isEmpty { stopUpdates() }
        }
    }

    private func emitError(id: Int, code: Int, message: String) {
        let safeMessage = message.replacingOccurrences(of: "'", with: "\\'")
        evaluate("window.__nativeError(\(id), \(code), '\(safeMessage)');")
    }

    private func evaluate(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
