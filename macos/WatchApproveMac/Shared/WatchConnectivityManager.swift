import Foundation

#if canImport(WearConnectivity)
import WearConnectivity
#endif

// MARK: - Stub for compile when WatchConnectivity is unavailable

class WatchConnectivityManager {
    static let shared = WatchConnectivityManager()
    var onWatchDecision: ((String, Decision) -> Void)?
    func syncApproval(_ approval: Approval) {}
    private init() {}
}
