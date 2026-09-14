# Tích hợp với plugin `claude-account`

App dùng lại toàn bộ store của CLI (`~/.claude/accounts/`, Keychain `Claude Code-credentials-acct-<name>`)
và gọi CLI cho mọi thao tác ghi snapshot (`use`, `save`, `remove`, `rename`, `login`). Không cần sửa
plugin để app chạy. Patch trong thư mục này là **tuỳ chọn**, giải quyết một điểm còn sót khi nhiều
session của 2 account chạy chồng nhau:

| Khi app đang chạy | Không patch | Có patch |
|---|---|---|
| Statusline của session account CŨ (còn sống sau khi hop) gọi `claude-account quota 9x` | Ghi 9x% vào `.quota` của account MỚI (gán nhầm theo `~/.claude.json`); app ghi đè lại từ API trong ≤ 1 chu kỳ đo | `quota` thấy app còn sống → không ghi, chỉ in `.hop` nếu có |
| Cùng lúc `quota` xoá/tạo `.hop` toàn cục | Có thể làm session account mới restart 1 lần nếu có account thứ 3 rảnh | Không đụng `.hop` |

Với 2 account (m04/m19) khác biệt chỉ là hiển thị nhiễu vài chục giây trên statusline. Với ≥3 account
nên apply patch.

## Apply

Patch viết dạng mô tả (hunk không có số dòng) vì file plugin có thể đổi theo version. Sửa tay 2 chỗ trong
`plugins/claude-account/scripts/claude-account.sh` của repo `~/Code/dls-ai-team`:

1. Thêm hàm `switcher_alive()` cạnh các helper `quota_file()`.
2. Đầu `cmd_quota()`, ngay sau `[ -n "$pct" ] || return 0`, thêm block `if switcher_alive; then ... fi`.

Nội dung chính xác trong `claude-account-plugin.patch`. Sau đó bump version plugin, commit, `/plugin update`.

## Hook của app vs hook của plugin

| | Plugin (`autohop-stop.sh`) | App (`~/.local/bin/claude-switcher-hook`) |
|---|---|---|
| Cờ | `accounts/.hop` toàn cục — MỌI session restart ở turn kế tiếp khi cờ tồn tại | `.switcher/restart.json` theo **pid** — chỉ session được liệt kê |
| Ai quyết định | Statusline của session vượt 90% | App, từ usage API của tất cả account |
| StopFailure(rate_limit) | Ghi 100% cho account live, cắm `.hop` | Ghi `events.log`, chờ tối đa 5s cho app lên plan, rồi restart đúng pid |
| Relaunch | `claude-as` loop đọc `.hop` → `use` → `--continue` | Giống hệt: hook ghi `.hop=<target>` ngay trước `kill -TERM` để loop đọc |

Hai hook sống chung được: hook plugin chỉ hành động khi `.hop` tồn tại, mà app chỉ tạo `.hop` trong
khoảng mili-giây trước khi kill đúng pid.
