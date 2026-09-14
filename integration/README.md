# Sống chung với plugin `claude-account`

App standalone, không cần plugin. Máy nào có cả hai thì dùng chung được vì app cố ý giữ cùng format:

| | Plugin `claude-account` | App `claude-switcher` |
|---|---|---|
| Snapshot token | Keychain `Claude Code-credentials-acct-<name>` | giống |
| Profile | `~/.claude/accounts/<name>.json` `{name, saved_at, subscriptionType, oauthAccount}` | giống (keys sort theo alphabet) |
| `.current`, `.quota`, `.hop` | ghi/đọc | ghi/đọc cùng format |
| Block shell | `# >>> claude-account >>> … <<<` gọi `claude-account use` | cùng marker, gọi `claude-switcher use`; installer nào chạy sau thì thay block |
| Hook restart | `autohop-stop.sh`: cờ `.hop` toàn cục, mọi session restart | `claude-switcher hook`: theo pid trong `.switcher/restart.json`, marker `hop-<id>` riêng từng loop |
| Relaunch | loop plugin đọc `.hop` | loop app đọc `hop-<id>`, fallback `.hop` |

Hook app nhận ra loop của plugin (có `CLAUDE_AS_LOOP=1`, không có `CLAUDE_AS_ID`) và ghi `.hop` cho nó —
nên session mở bằng `claude-as` của plugin vẫn hop được. Hai hook chạy song song không xung đột: hook plugin chỉ
hành động khi `.hop` tồn tại, app chỉ tạo `.hop` trong khoảng mili-giây trước khi kill đúng pid.

Điểm còn sót khi app chạy trên máy có statusline của plugin: `claude-account quota` của session account CŨ ghi
usage vào `.quota` của account MỚI (gán theo `~/.claude.json`); app ghi đè lại từ API trong ≤ 1 chu kỳ đo. Patch
`claude-account-plugin.patch` (tuỳ chọn) làm `quota` nhường quyền khi thấy heartbeat `.switcher/alive`.
