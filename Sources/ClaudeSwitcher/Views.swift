import SwiftUI
import ClaudeSwitcherCore

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let live = model.liveName ?? model.liveAccount?.emailAddress?.split(separator: "@").first.map(String.init) ?? "?"
        let eff = model.liveName.flatMap { model.effective($0) }
        let pct = eff.map { Format.pct($0.fiveHour) } ?? ""
        HStack(spacing: 3) {
            Image(systemName: symbol(eff))
            Text(pct.isEmpty ? live : "\(live) \(pct)")
        }
    }

    private func symbol(_ e: Effective?) -> String {
        guard let e else { return "person.crop.circle.badge.questionmark" }
        if model.drift != nil { return "exclamationmark.triangle" }
        if e.fiveHour >= AppSettings.hopAt { return "person.crop.circle.badge.exclamationmark" }
        if e.fiveHour >= 70 { return "person.crop.circle.badge.clock" }
        return "person.crop.circle.badge.checkmark"
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showSave = false
    @State private var showSessions = false
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var saveName = ""
    @State private var confirmRestart: Session?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.setup.complete { setupBanner }
            if model.profiles.isEmpty {
                Text("Chưa có account nào được lưu. Bấm “Lưu login hiện tại” để bắt đầu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { p in
                AccountRow(profile: p)
            }
            Divider()
            policyRow
            if let d = model.drift { driftRow(d) }
            if let plan = model.plan { planRow(plan) }
            sessionsRow
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Claude Switcher").font(.headline)
            Spacer()
            if let t = model.busyText {
                ProgressView().controlSize(.small)
                Text(t).font(.caption).foregroundStyle(.secondary)
            } else if let at = model.lastPollAt {
                Text("đo \(Format.ago(at)) trước").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.pollUsage(force: true); await model.scanSessions() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Đo lại quota + quét session")
        }
    }

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.badge.clock").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hop tự động chưa sẵn sàng: thiếu \(model.setup.missing.joined(separator: ", ")).")
                    .font(.caption)
                Button("Cài (shim + hook + claude-as, có backup)") { Task { await model.installAll() } }
                    .controlSize(.small).disabled(model.busy)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private var policyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $model.autoSwitch) {
                Text("Tự hop khi 5h ≥ \(Int(AppSettings.hopAt))%").font(.callout)
            }.toggleStyle(.switch).controlSize(.small)
            Text(decisionText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var decisionText: String {
        switch model.decision {
        case .stay(let s): return "Ổn: \(s)"
        case .hop(let to, let reason): return model.autoSwitch ? "Sẽ hop → \(to) (\(reason))" : "Nên hop → \(to) (\(reason)) — auto đang tắt"
        case .allExhausted(let next): return "Tất cả account đều hết quota" + (next.map { ", reset sớm nhất \(Format.clock($0))" } ?? "")
        case .hold(let why): return "Chờ: \(why)"
        }
    }

    private func driftRow(_ d: DriftInfo) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keychain lệch: token live thuộc \(d.tokenAccountName ?? d.tokenEmail ?? "?"), config nói \(d.configName ?? "?")").font(.caption)
                Button("Sửa lệch (lưu token về đúng snapshot, khôi phục \(d.configName ?? "?"))") { Task { await model.realign() } }
                    .controlSize(.small)
            }
        }
    }

    private func planRow(_ plan: RestartPlan) -> some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
            Text("\(plan.pids.count) session sẽ restart --continue sang \(plan.to) ở cuối turn").font(.caption)
            Spacer()
            Button("Huỷ") { model.cancelPlan() }.controlSize(.mini)
        }
    }

    private var sessionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showSessions.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSessions ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("\(model.sessions.count) session claude đang chạy").font(.callout)
                    Spacer()
                    Text(sessionSummary).font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            if showSessions {
                ForEach(model.sessions) { s in
                    HStack(spacing: 6) {
                        Text(String(s.pid)).font(.caption.monospaced()).frame(width: 46, alignment: .leading)
                        Text(accountLabel(s)).font(.caption).frame(width: 60, alignment: .leading)
                        Text(s.cwd.map { ($0 as NSString).lastPathComponent } ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(Format.ago(s.startedAt)).font(.caption2).foregroundStyle(.secondary)
                        if !s.isLoop {
                            Text("no loop").font(.caption2).foregroundStyle(.orange).help("Không chạy qua claude-as: không tự relaunch được")
                        }
                        if model.plan?.pids[String(s.pid)] != nil {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.blue).help("Sẽ restart ở cuối turn")
                        }
                        if s.account.name != model.liveName || s.account.isAssumed {
                            Button { confirmRestart = confirmRestart?.pid == s.pid ? nil : s } label: { Image(systemName: "restart") }
                                .buttonStyle(.borderless).controlSize(.mini).disabled(!s.isLoop)
                                .help("Restart ngay bằng account live (--continue)")
                        }
                    }
                    if confirmRestart?.pid == s.pid {
                        HStack(spacing: 6) {
                            Text("SIGTERM pid \(s.pid): turn đang chạy bị cắt, text đang gõ mất; claude-as mở lại bằng \(model.liveName ?? "?") --continue.")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button("Restart", role: .destructive) { Task { await model.restartNow(s) }; confirmRestart = nil }
                            Button("Huỷ") { confirmRestart = nil }
                        }.controlSize(.mini)
                    }
                }
                if !model.setup.hookWired {
                    Text("Hook chưa cài → session không tự restart khi hop. Bấm Cài ở banner trên hoặc Cài đặt › Shell.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var sessionSummary: String {
        var counts: [String: Int] = [:]
        for s in model.sessions { counts[s.account.name ?? "?", default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    private func accountLabel(_ s: Session) -> String {
        switch s.account {
        case .known(let n): return n
        case .assumed(let n): return "~\(n)"
        case .unknown: return "?"
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(showAdd ? "Đóng" : "Thêm account…") { showAdd.toggle(); showSave = false }
                Button(showSave ? "Đóng" : "Lưu login hiện tại…") { showSave.toggle(); showAdd = false }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Cài đặt")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("Thoát")
            }
            .controlSize(.small)
            if showAdd {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mở Terminal chạy `claude-switcher login <tên>`: đăng nhập account KHÁC trong config dir tạm, login hiện tại không bị đụng.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        TextField("tên (vd m07)", text: $newName).textFieldStyle(.roundedBorder)
                        TextField("email (tuỳ chọn)", text: $newEmail).textFieldStyle(.roundedBorder)
                        Button("Đăng nhập") {
                            Task { await model.addAccount(name: newName.trimmingCharacters(in: .whitespaces), email: newEmail.trimmingCharacters(in: .whitespaces)) }
                            showAdd = false
                        }.disabled(newName.isEmpty)
                    }.controlSize(.small)
                }
            }
            if showSave {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snapshot login đang có trong Keychain dưới một tên (\(model.liveAccount?.emailAddress ?? "chưa login")).")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        TextField("tên", text: $saveName).textFieldStyle(.roundedBorder)
                        Button("Lưu") { Task { await model.saveCurrent(as: saveName.trimmingCharacters(in: .whitespaces)) }; showSave = false }
                            .disabled(saveName.isEmpty)
                    }.controlSize(.small)
                }
            }
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let profile: AccountProfile
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var isLive: Bool { model.liveName == profile.name }

    var body: some View {
        let eff = model.effective(profile.name)
        let u = model.usage[profile.name]
        let sessions = model.sessions.filter { $0.account.name == profile.name }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(isLive ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(profile.name).font(.system(.body, design: .rounded).weight(.semibold))
                if isLive { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                Text("\(profile.email) · \(profile.plan) · \(profile.org)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !isLive {
                    Button("Chuyển") { Task { await model.performSwitch(to: profile.name, auto: false) } }
                        .controlSize(.small).disabled(model.busy)
                }
                Menu {
                    Button("Đổi tên…") { newName = profile.name; renaming = true; confirmingRemove = false; nameFocused = true }
                    Button("Xoá snapshot…", role: .destructive) { confirmingRemove = true; renaming = false }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 20)
            }
            if confirmingRemove {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isLive
                         ? "Xoá snapshot '\(profile.name)'? Account đang live: login vẫn giữ nhưng thành “chưa lưu” (không tự hop được cho tới khi Lưu lại). Muốn dùng lại sau phải đăng nhập lần nữa."
                         : "Xoá snapshot '\(profile.name)' (Keychain item + profile)? Login live không bị đụng. Muốn dùng lại phải đăng nhập lần nữa.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Xoá", role: .destructive) { Task { await model.remove(profile.name) }; confirmingRemove = false }
                            .disabled(model.busy)
                        Button("Huỷ") { confirmingRemove = false }
                    }.controlSize(.small)
                }
            }
            if renaming {
                HStack(spacing: 6) {
                    TextField("tên mới", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { Task { if await model.rename(profile.name, to: newName) { renaming = false } } }
                    Button("Lưu") { Task { if await model.rename(profile.name, to: newName) { renaming = false } } }
                        .disabled(model.busy || newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == profile.name)
                    Button("Huỷ") { renaming = false }
                }
                .controlSize(.small)
                Text("Đổi tên snapshot (Keychain item, profile, lịch sử). Login live không đổi; tên dùng trong `claude-as <tên>`.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let eff {
                bar("5h", eff.fiveHour, eff.fiveResetsAt, threshold: AppSettings.hopAt)
                if let seven = eff.sevenDay { bar("7d", seven, eff.sevenResetsAt, threshold: AppSettings.sevenDayAt) }
            }
            HStack(spacing: 8) {
                Text(sourceText(eff, u)).font(.caption2).foregroundStyle(.secondary)
                if sessions > 0 { Text("\(sessions) session").font(.caption2).foregroundStyle(.secondary) }
                if let extras = u?.extras, !extras.isEmpty {
                    Text(extras.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "seven_day_", with: "7d ")) \(Format.pct($0.value.pct))" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isLive ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06)))
    }

    private func bar(_ label: String, _ pct: Double, _ reset: Date?, threshold: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).frame(width: 18, alignment: .leading)
            ProgressView(value: min(max(pct, 0), 100), total: 100)
                .tint(pct >= threshold ? .red : pct >= 70 ? .orange : .green)
            Text(Format.pct(pct)).font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
            Text(reset.map { "→ \(Format.clock($0))" } ?? "").font(.caption2).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
        }
    }

    private func sourceText(_ eff: Effective?, _ u: AccountUsage?) -> String {
        guard let eff else { return "chưa đo" }
        switch eff.source {
        case .api: return "API \(u.map { Format.ago($0.fetchedAt) } ?? "") trước"
        case .recorded: return "số đã ghi" + (u?.error.map { " · \($0)" } ?? "")
        case .event: return "rate limit từ session"
        case .none: return u?.error ?? "chưa đo"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppSettings.Key.hopAt.rawValue) private var hopAt = 90
    @AppStorage(AppSettings.Key.sevenDayAt.rawValue) private var sevenDayAt = 100
    @AppStorage(AppSettings.Key.pollSeconds.rawValue) private var pollSeconds = 60
    @AppStorage(AppSettings.Key.notify.rawValue) private var notify = true
    @AppStorage(AppSettings.Key.terminalApp.rawValue) private var terminalApp = "Terminal"
    @AppStorage(AppSettings.Key.restartSessions.rawValue) private var restartSessions = true
    @AppStorage(AppSettings.Key.cooldownMinutes.rawValue) private var cooldown = 10
    @State private var extraPath = AppSettings.defaults.string(forKey: AppSettings.Key.extraPath.rawValue) ?? ""
    @State private var confirmUninstall = false

    var body: some View {
        TabView {
            general.tabItem { Label("Chung", systemImage: "slider.horizontal.3") }
            shell.tabItem { Label("Shell", systemImage: "terminal") }
            doctor.tabItem { Label("Doctor", systemImage: "stethoscope") }
            uninstall.tabItem { Label("Gỡ cài đặt", systemImage: "trash") }
        }
        .frame(width: 520, height: 420)
        .padding()
    }

    private var general: some View {
        Form {
            Toggle("Tự hop account khi hết quota", isOn: $model.autoSwitch)
            percentRow("Hop khi 5h ≥", value: $hopAt, hint: "100 = chỉ hop khi cạn hẳn (hoặc session báo rate limit)")
            percentRow("Coi là hết khi 7d ≥", value: $sevenDayAt, hint: "account có 7d ≥ ngưỡng không được chọn làm đích")
            Picker("Đo quota mỗi", selection: $pollSeconds) {
                Text("30s").tag(30); Text("1 phút").tag(60); Text("2 phút").tag(120); Text("5 phút").tag(300)
            }
            Stepper("Cooldown giữa 2 lần tự hop: \(cooldown) phút", value: $cooldown, in: 1...60)
            Toggle("Lên lịch restart --continue cho session của account cũ (cần hook)", isOn: $restartSessions)
            Toggle("Thông báo macOS", isOn: $notify)
            Toggle("Chạy khi đăng nhập máy", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Picker("Terminal cho đăng nhập", selection: $terminalApp) {
                Text("Terminal").tag("Terminal"); Text("iTerm").tag("iTerm")
            }
            Text("Đo bằng token OAuth sẵn trong Keychain (chỉ đọc, không refresh). Account không live: token hết hạn sau vài giờ → dùng số .quota đã ghi, cửa sổ đã reset tính 0% (giống `claude-account next`).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    /// Typed percent with arrows; clamped to 1...100, re-evaluates the policy on change.
    private func percentRow(_ title: String, value: Binding<Int>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("%")
                Stepper("", value: value, in: 1...100).labelsHidden()
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: value.wrappedValue) { _, v in
            if v < 1 { value.wrappedValue = 1 } else if v > 100 { value.wrappedValue = 100 }
            model.evaluate()
        }
    }

    private var shell: some View {
        Form {
            Section("Hop tự động cần 3 thứ trên máy") {
                statusRow(model.setup.shim == .current, model.setup.shim == .current ? "Shim \(Paths.shim.path) → app" : model.setup.shim == .stale ? "Shim trỏ sai chỗ (app đã chuyển) → Cài lại" : "Chưa có shim \(Paths.shim.path)")
                statusRow(model.setup.hookWired, model.setup.hookWired ? "Hook Stop/StopFailure trong ~/.claude/settings.json" : "Hook chưa có trong ~/.claude/settings.json")
                statusRow(model.setup.rc != .missing, model.setup.rc == .ours ? "claude-as + alias claude trong \(ShellInstaller.rcFile().path)" : model.setup.rc == .plugin ? "claude-as của plugin claude-account trong \(ShellInstaller.rcFile().lastPathComponent) (dùng được)" : "Chưa có claude-as trong \(ShellInstaller.rcFile().path)")
                HStack {
                    Button(model.setup.complete ? "Cài lại" : "Cài tất cả") { Task { await model.installAll() } }.disabled(model.busy)
                    Button("Gỡ tích hợp shell") { Task { await model.removeShellIntegration() } }.disabled(model.busy)
                }
                Text("`claude` được alias sang claude-as: vòng lặp mở claude, và khi hook của app kết thúc session ở cuối turn (pid nằm trong .switcher/restart.json), vòng lặp đổi account rồi chạy `claude --continue`. Session của account mới không bị đụng. Session đang chạy chỉ nhận hook sau khi restart. Mọi file sửa đều có backup .bak-*.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tìm `claude`") {
                TextField("PATH thêm (vd /opt/homebrew/bin:/Users/x/.nvm/versions/node/v24/bin)", text: $extraPath)
                    .onSubmit { model.setExtraPath(extraPath) }
                Text("Đăng nhập account mới chạy `claude auth login`; app tự thêm ~/.local/bin, Homebrew và nvm mới nhất vào PATH.").font(.caption).foregroundStyle(.secondary)
            }
            Section("CLI") {
                Text("`claude-switcher list | current | save | use | login | remove | rename | next | status | doctor | install | uninstall` — cùng thao tác như menu, dùng được trong script.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statusRow(_ ok: Bool, _ text: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .orange)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private var uninstall: some View {
        Form {
            Section("Gỡ Claude Switcher") {
                Text("Xoá: hook Stop/StopFailure trong ~/.claude/settings.json (có backup), shim ~/.local/bin/claude-switcher, block claude-as + alias trong shell rc (nếu là của app), mục “Chạy khi đăng nhập máy”, thư mục ~/.claude/accounts/.switcher/, preferences, và chính app (vào Thùng rác). App thoát sau khi gỡ.")
                    .font(.callout)
                Text(Uninstaller.keeps).font(.caption).foregroundStyle(.secondary)
                Text("Không GUI: `claude-switcher uninstall --dry-run` xem trước, bỏ `--dry-run` để gỡ; hoặc Uninstall.command trong file .dmg.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Gỡ cài đặt…", role: .destructive) { confirmUninstall = true }
                    .disabled(model.busy)
            }
        }
        .formStyle(.grouped)
        .alert("Gỡ Claude Switcher?", isPresented: $confirmUninstall) {
            Button("Gỡ", role: .destructive) { Task { await model.uninstall() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(Uninstaller.plan(removeApp: true).map { "• " + $0.what }.joined(separator: "\n") + "\n\n" + Uninstaller.keeps)
        }
    }

    private var doctor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Kiểm tra") { Task { await model.runDoctor() } }
                Spacer()
                Text("log: \(Paths.appLog.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(model.doctorItems) { item in
                HStack(alignment: .top) {
                    Image(systemName: item.level == .ok ? "checkmark.circle.fill" : item.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(item.level == .ok ? .green : item.level == .warn ? .orange : .red)
                    Text(item.text).font(.callout).textSelection(.enabled)
                }
            }
        }
        .task { if model.doctorItems.isEmpty { await model.runDoctor() } }
    }
}
