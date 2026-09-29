# Sống chung với plugin `claude-account`

Từ 2026-09-20 plugin nằm luôn trong repo này tại `plugins/claude-account/` (lịch sử 5 commit giữ nguyên,
tách từ repo team bằng `git subtree split`). Hai sản phẩm, một hợp đồng trên đĩa — đổi format `.hop`,
`.quota` hay block shell thì sửa cả hai phía trong cùng một commit.

App standalone, không cần plugin. Máy nào có cả hai thì dùng chung được vì app cố ý giữ cùng format:

| | Plugin `claude-account` | App `claude-switcher` |
|---|---|---|
| Snapshot token | Keychain `Claude Code-credentials-acct-<name>` | giống |
| Profile | `~/.claude/accounts/<name>.json` `{name, saved_at, subscriptionType, oauthAccount}` | giống (keys sort theo alphabet) |
| `.current`, `.quota`, `.hop` | ghi/đọc | ghi/đọc cùng format |
| Block shell | `# >>> claude-account >>> … <<<` gọi `claude-account use` | cùng marker, gọi `claude-switcher use`; installer nào chạy sau thì thay block |
| Hook restart | `autohop-stop.sh`: cờ `.hop` toàn cục, mọi session restart | `claude-switcher hook`: theo pid trong `.switcher/restart.json`, marker `hop-<id>` riêng từng loop |
| Relaunch | loop plugin đọc `.hop`, `--continue` | loop app đọc `hop-<id>` (+ `hop-<id>.session` → `--resume <id>`), fallback `.hop`; `use` lỗi → vẫn resume |
| Blob dùng được | có cả `accessToken` và `refreshToken` (`is_oauth_blob`) | giống (`OAuthBlob.isComplete`) |
| Lock | `lockf`/`flock` trên `.switcher/lock` (bash fallback) | `flock(2)` trên cùng file |

## Đồng bộ CLI ↔ app (0.5 / plugin 0.3)

Sự cố 2026-09-25 → 28: hai bản cài đặt của cùng một luật đã lệch nhau. Plugin coi blob là dùng được khi có
`refreshToken`; app đòi thêm `accessToken`. Snapshot m19 mất token thật (đổi account lúc Keychain đang lệch → token m04
bị cất vào `acct-m19`), sau đó ping cron vẫn `claude-account use m19` được, còn app báo "không đọc được Keychain" và
chuyển thất bại mỗi lần. Cách giữ hai phía không lệch nữa:

1. **Một bản cài đặt cho mọi lệnh ghi.** Có app (`~/.local/bin/claude-switcher` chạy được) thì `claude-account`
   `save | use | login | remove | rename` `exec` sang `claude-switcher` cùng tham số. Luật snapshot (cất token live về
   chủ thật, không `use` snapshot chết hay sai chủ), lock và lịch sử đều của app. `CLAUDE_ACCOUNT_NO_APP=1` tắt.
   Lệnh đọc (`list`, `current`, `names`, `quota`) vẫn là bash — statusline gọi `quota` mỗi lần render. `next`
   (cả lúc `quota` chọn đích cho `.hop`) hỏi `claude-switcher next`: app xếp theo 5h + 7d từ API (7d trước khi bật
   "ưu tiên 7d thấp"), còn `.quota` chỉ có số 5h.
2. **Không có app** → bash tự làm, dưới cùng lock file app dùng (`lockf -k` trên macOS, `flock` trên Linux; đã thử:
   `lockf` chờ khi một process giữ `flock(2)`). Luật blob giống hệt; `next` bỏ qua snapshot không dùng được.
   Bash chưa hỏi `/api/oauth/profile`, nên máy chỉ có plugin vẫn cất token live theo `~/.claude.json`.
3. **Một ngày sau:** đổi luật (blob, format marker, block shell) thì sửa `Keychain.swift` / `claude-account.sh` /
   `ShellInstaller.rcBlock` / `install.sh` trong cùng commit; `Checks/` giữ các ca của luật blob và quyết định
   snapshot.

Máy đang cài plugin từ marketplace khác (vd `claude-account@dls-ai-team` 0.2.3) chưa nhận điểm 1–2 cho tới khi cài
lại từ repo này:

```
/plugin marketplace add pein1625/claude-account-switcher
/plugin install claude-account@claude-account-switcher
```

Hook app nhận ra loop của plugin (có `CLAUDE_AS_LOOP=1`, không có `CLAUDE_AS_ID`) và ghi `.hop` cho nó —
nên session mở bằng `claude-as` của plugin vẫn hop được. Hai hook chạy song song không xung đột: hook plugin chỉ
hành động khi `.hop` tồn tại, app chỉ tạo `.hop` trong khoảng mili-giây trước khi kill đúng pid.

Khi app chạy (heartbeat `.switcher/alive` < 120s) plugin **nhường mọi quyết định hop**: `claude-account quota`
(statusline) không ghi `.quota` / `.hop` nữa, `autohop-stop.sh` không kill session. Trước đó hai chính sách chạy
song song — plugin hop ở 5h ≥ 90% theo số statusline, app theo tiến độ tuần của mọi account — và `quota` của session
account CŨ ghi usage vào `.quota` của account MỚI (gán theo `~/.claude.json`). Tắt app → plugin làm như cũ.
