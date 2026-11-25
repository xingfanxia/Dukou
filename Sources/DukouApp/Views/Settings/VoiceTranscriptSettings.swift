import DukouCore
import DukouWeChatDatabase
import SwiftUI

/// The switch for reading voice transcripts out of WeChat's own database,
/// and what a check found once it is on. See `WeChatDatabase`.
///
/// The check is the first time Dukou reads WeChat's folder, so it is also
/// what makes macOS ask whether Dukou may; it runs off the main thread and
/// waits for that answer.
struct VoiceTranscriptSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var status: WeChatDatabase.Status?

    var body: some View {
        SettingsSection(title: L10n.text("语音转文字"), systemImage: "waveform") {
            SettingRow(
                title: L10n.text("从微信本地数据库读取语音转文字"),
                detail: L10n.text("需要 chatlog 已保存在 ~/.chatlog/chatlog.json 的密钥。只读，内容不离开这台 Mac。打开后，手动转发的语音会在转发后一秒左右补上微信里转出的文字，直接写进那个 ZIP。"),
                alignment: .center
            ) {
                Toggle(L10n.text("从微信本地数据库读取语音转文字"), isOn: $preferences.readsVoiceTranscriptsFromDatabase)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .accessibilityIdentifier("entries.voiceTranscriptsFromDatabase")
            }
            if preferences.readsVoiceTranscriptsFromDatabase {
                if let status {
                    Notice(Self.text(of: status), tone: status == .ready ? .good : .warn)
                } else {
                    Notice(L10n.text("正在检查…"))
                }
            }
        }
        .task(id: preferences.readsVoiceTranscriptsFromDatabase) {
            status = nil
            guard preferences.readsVoiceTranscriptsFromDatabase else { return }
            status = await Task.detached { WeChatDatabase.check() }.value
        }
    }

    private static func text(of status: WeChatDatabase.Status) -> String {
        switch status {
        case .ready: L10n.text("已就绪：找到了微信的数据库和能打开它的密钥。")
        case .noKeyFile: L10n.text("找不到密钥：~/.chatlog/chatlog.json 不存在，或里面没有密钥。")
        case .keyMismatch: L10n.text("密钥对不上：chatlog 保存的密钥都打不开当前微信账号的数据库。")
        case .denied: L10n.text("macOS 拒绝了 Dukou 读取微信的数据，可在「系统设置 → 隐私与安全性」里更改。")
        case .unreadable: L10n.text("读不到微信的数据文件夹。")
        }
    }
}
