CLAUDE SWITCHER - cai dat / installation

Cach nhanh nhat, khong bi Gatekeeper hoi (tai bang curl thay cho trinh duyet):
    curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash
Con dung file dmg nay thi:

1. Keo ClaudeSwitcher.app vao thu muc Applications (bieu tuong ben canh).

2. Mo app tu Applications. macOS se chan vi app chua notarize (ky adhoc):
     "ClaudeSwitcher" chua duoc mo / Not Opened - Apple khong the xac minh... / could not verify...
   Bam "Xong" (Done), KHONG bam "Chuyen vao Thung rac". Roi lam MOT trong hai:
     a) System Settings > Quyen rieng tu & Bao mat (Privacy & Security) > keo xuong cuoi
        > dong "ClaudeSwitcher da bi chan..." > "Van mo" (Open Anyway) > Touch ID/mat khau > mo app lai.
        (Nut "Van mo" chi hien ~1 gio sau lan bi chan; khong thay -> mo app lan nua roi vao lai.)
     b) Terminal:   xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app
   macOS 15+ khong con right-click > Open cho app chua ky.

3. App hoi "Bat hop tu dong?" -> Cai. No ghi:
     ~/.local/bin/claude-switcher            (CLI)
     hook Stop/StopFailure vao ~/.claude/settings.json   (co backup)
     ham claude-as + alias claude vao ~/.zshrc (hoac ~/.bashrc)   (co backup)
   Mo terminal moi sau do. Cho phep thong bao khi duoc hoi. Icon nam tren menu bar canh dong ho.

4. Lan dau dung: "Luu login hien tai..." dat ten cho account dang dang nhap, roi "Them account..."
   cho account thu hai (mo Terminal, dang nhap 1 lan, login hien tai khong bi dung).
   Trinh duyet dang dang nhap claude.ai bang account nao thi se lay account do -> muon account khac,
   dang xuat claude.ai truoc hoac mo URL trong cua so rieng tu.

Yeu cau: macOS 14+, Intel hoac Apple Silicon; Claude Code da dang nhap claude.ai (Pro/Max/Team).
Khong can cai them gi khac.

Token gan theo may: KHONG copy ~/.claude/accounts hay Keychain tu may khac sang.

Go cai dat:  mo app > (gear) > "Go cai dat", hoac trong Terminal:
    bash "/Volumes/Claude Switcher/Uninstall.command"
Go: app, hook, shim, block claude-as, ~/.claude/accounts/.switcher, preferences, login item.
KHONG dung den snapshot account hay login hien tai.
