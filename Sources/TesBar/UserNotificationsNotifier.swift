@preconcurrency import Foundation
@preconcurrency import UserNotifications

/// 生产通知：UNUserNotificationCenter。首次发送时请求授权（失败才走到这里，授权被拒不抛错）。
public actor UserNotificationsNotifier: Notifier {
    private var authorized = false

    public init() {}

    public func send(title: String, body: String) async {
        if !authorized {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            authorized = true
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
