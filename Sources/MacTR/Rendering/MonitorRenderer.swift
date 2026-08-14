// MonitorRenderer.swift — System Monitor 3-panel dashboard
//
// Set 1: CPU | AI AGENTS (triple width) | MEMORY
// The AGENTS panel shows each agent's current activity (top) and today's
// token usage + quota (bottom), sourced from local session transcripts.
// Left / right columns are freely remappable among Claude / Codex / Cursor
// via AgentKind.left / AgentKind.right (Settings → Agents).

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
    private let lock = NSLock()

    // Cached snapshots (written by metricsQueue, read by render thread)
    private var _cpu: CPUSnapshot?
    private var _mem: MemorySnapshot?
    private var _temp: TemperatureSnapshot?
    private var _agents: AgentsSnapshot?
    private var _sys: SystemSnapshot?

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

    // Test mode (--test-flash): force both columns into the flashing state until
    // this deadline, to preview the alert visuals without waiting for a real event
    private var testFlashUntil: Date?

    func enableTestFlash(seconds: TimeInterval) {
        testFlashUntil = Date().addingTimeInterval(seconds)
        log("[Metrics] Test flash enabled for \(Int(seconds))s")
    }

    private func withAttention(_ u: AgentUsage) -> AgentUsage {
        AgentUsage(available: u.available,
                   todayInputTokens: u.todayInputTokens,
                   todayOutputTokens: u.todayOutputTokens,
                   secondsSinceActive: u.secondsSinceActive,
                   project: u.project, activity: u.activity,
                   quotaUsedPercent: u.quotaUsedPercent,
                   quotaResetsAt: u.quotaResetsAt,
                   needsAttention: true,
                   waitingFor: u.waitingFor, model: u.model,
                   stepCurrent: u.stepCurrent, stepTotal: u.stepTotal,
                   stepText: u.stepText,
                   hasTokenUsage: u.hasTokenUsage)
    }

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        lock.lock()
        guard !metricsRunning else { lock.unlock(); return }
        metricsRunning = true
        lock.unlock()
        log("[Metrics] Starting collection...")
        // First pass: prime CPU ticks (deltas will be zero)
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let temp = collector.collectTemperature()
        let agents = agentCollector.collect()
        let sys = collector.collectSystem()
        lock.lock()
        _cpu = cpu0; _mem = mem
        _temp = temp; _agents = agents; _sys = sys
        lock.unlock()

        // Second pass: get real CPU deltas
        Thread.sleep(forTimeInterval: 0.3)
        let cpu1 = collector.collectCPU()
        lock.lock()
        _cpu = cpu1
        lock.unlock()

        // Start async collection loop
        metricsQueue.async { [weak self] in self?.metricsLoop() }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        metricsRunning = false
    }

    /// True when a column has a live animation (breathing while working, or the
    /// done/waiting blink) — the frame loop uses this to raise the LCD frame rate
    /// only while something is actually moving, and idle low otherwise.
    func wantsHighFrameRate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Heavy CPU → Pikachu crackles with electricity, worth animating smoothly
        if let c = _cpu, c.total > 55 { return true }
        guard let a = _agents else { return false }
        let left = a.usage(for: AgentKind.left)
        let right = a.usage(for: AgentKind.right)
        return left.isWorking || left.needsAttention
            || right.isWorking || right.needsAttention
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        while metricsRunning {
            // This loop is a single never-returning GCD work item, so its implicit
            // autorelease pool is never drained. Everything autoreleased below —
            // JSONSerialization's NSDictionary/CFString graphs, attributesOfItem
            // dictionaries, FileHandle's NSData buffers — would accumulate for the
            // life of the process (~2GB/hour). Drain it every tick.
            autoreleasepool {
                // Fast metrics every tick
                let cpu = collector.collectCPU()
                let mem = collector.collectMemory()
                lock.lock()
                _cpu = cpu; _mem = mem
                lock.unlock()

                // Slow metrics every 4th tick (~2s)
                slowTick += 1
                if slowTick >= 4 {
                    let temp = collector.collectTemperature()
                    let agents = agentCollector.collect()
                    let sys = collector.collectSystem()
                    lock.lock()
                    _temp = temp; _agents = agents; _sys = sys
                    lock.unlock()
                    slowTick = 0
                }
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    // Demo mode: drive the display with polished fake data (for screenshots / photos
    // and open-source showcase). Set before render(); the frame loop keeps its normal
    // memory-safe path (reusable context + autoreleasepool) and animations stay live.
    var demoMode = false

    /// Deterministic showcase data. CPU cores gently wave over time so the demo looks
    /// alive on the LCD; everything else is fixed so it reads clearly in a photo.
    private func demoData() -> (CPUSnapshot, MemorySnapshot, TemperatureSnapshot,
                                SystemSnapshot, AgentsSnapshot) {
        let tt = Date().timeIntervalSince1970
        let cores: [Double] = (0..<10).map { i in
            let wave: Double = sin(tt * 1.3 + Double(i) * 0.9)
            return 25.0 + 55.0 * (0.5 + 0.5 * wave)
        }
        let total: Double = cores.reduce(0.0, +) / 10.0
        let cpu = CPUSnapshot(perCore: cores, total: total,
                              loadAvg: (3.5, 4.2, 3.8), pCoreCount: 8)
        let gb: UInt64 = 1024 * 1024 * 1024
        let mem = MemorySnapshot(
            total: 32 * gb, active: 9 * gb, wired: 3 * gb,
            compressed: 2 * gb, available: 18 * gb,
            swapUsed: 512 * 1024 * 1024, swapTotal: 4 * gb,
            swapInPerSec: 0, swapOutPerSec: 0, swapAvailable: true, pressure: 1)
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let sys = SystemSnapshot(uptimeSeconds: 27 * 3600 + 3 * 60, processCount: 612)
        let agents = AgentsSnapshot(
            claude: AgentUsage(available: true,
                               todayInputTokens: 48_300_000, todayOutputTokens: 512_000,
                               secondsSinceActive: 3, project: "MacTR",
                               activity: """
                               已完成 AI Agents 面板的三项优化，改动集中在两个文件：

                               | 文件 | 改动 |
                               |---|---|
                               | Collector | 解析消息与待办 |
                               | Renderer | 表格化排版 |
                               """,
                               isWorking: true,
                               stepCurrent: 3, stepTotal: 4,
                               stepText: "渲染 Claude 消息表格"),
            codex: AgentUsage(available: true,
                              todayInputTokens: 60_100_000, todayOutputTokens: 375_000,
                              secondsSinceActive: 6, project: "web-service",
                              activity: """
                              已完成部署，四个服务全部推送到 `main`：

                              | 服务 | 提交 | 文件 |
                              |---|---|---:|
                              | `api-gateway` | `a4872c56` | 24 |
                              | `auth-service` | `4d6934de` | 10 |
                              | `web-client` | `9b0e17aa` | 32 |
                              | `job-worker` | `ac02bea6` | 88 |
                              """,
                              quotaUsedPercent: 57,
                              quotaResetsAt: Date().addingTimeInterval(3600 * 24 * 6),
                              isWorking: true,
                              stepCurrent: 4, stepTotal: 6,
                              stepText: "部署到预发环境并跑冒烟测试"),
            cursor: AgentUsage(available: true,
                               todayInputTokens: 0, todayOutputTokens: 0,
                               secondsSinceActive: 4, project: "ad-test-mini",
                               activity: """
                               落地页已填好并发布，公开链接与编辑器画布样式对齐。

                               | 页面 | 状态 |
                               |---|---|
                               | 编辑器 | 已刷新 |
                               | 公开 H5 | 样式匹配 |
                               """,
                               quotaUsedPercent: 48,
                               isWorking: true,
                               model: "gpt-5.6-sol",
                               stepCurrent: 2, stepTotal: 3,
                               stepText: "核对公开页样式",
                               hasTokenUsage: false))
        return (cpu, mem, temp, sys, agents)
    }

    /// Render one demo frame with the showcase data (for --snapshot).
    func renderSimulated(coreCount: Int) -> CGImage? {
        let (cpu, mem, temp, sys, agents) = demoData()
        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        Draw.gradientBackground(ctx)
        renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: true)
        renderAgents(ctx, agents: agents)
        renderMemory(ctx, mem: mem, sys: sys, agentsBusy: true)
        return ctx.makeImage()
    }

    // Serializes render() callers — the USB frame loop and the on-Mac preview
    // window can both render around a connect/disconnect transition, and they
    // share reusableCtx + sparkline history
    private let renderMutex = NSLock()

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        let cpu: CPUSnapshot, mem: MemorySnapshot, temp: TemperatureSnapshot
        let sys: SystemSnapshot?
        var agents: AgentsSnapshot
        if demoMode {
            (cpu, mem, temp, sys, agents) = demoData()
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            cpu = c; mem = m; temp = tp; agents = a; sys = _sys
            lock.unlock()
        }

        if let until = testFlashUntil, Date() < until {
            agents = AgentsSnapshot(claude: withAttention(agents.claude),
                                    codex: withAttention(agents.codex),
                                    cursor: withAttention(agents.cursor))
        }

        // Reuse CGContext to prevent CG raster data memory growth
        let w = Layout.width
        let h = Layout.height
        if reusableCtx == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            reusableCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = reusableCtx else { return nil }

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        Draw.gradientBackground(ctx)

        // Panels — only the two currently displayed columns drive the pets
        let leftU = agents.usage(for: AgentKind.left)
        let rightU = agents.usage(for: AgentKind.right)
        let agentsBusy = leftU.isWorking || leftU.needsAttention
            || rightU.isWorking || rightU.needsAttention
        renderCPU(ctx, cpu: cpu, temp: temp, agentsBusy: agentsBusy)
        renderAgents(ctx, agents: agents)
        renderMemory(ctx, mem: mem, sys: sys, agentsBusy: agentsBusy)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    /// Model id → a compact label that fits the header.
    ///   claude-opus-5              → Opus 5
    ///   claude-haiku-4-5-20251001  → Haiku 4.5
    ///   bapi_codex/gpt-5.6-sol     → GPT-5.6-sol
    /// Anything unrecognised falls through as-is (minus the provider prefix), so a
    /// new model shows up as its raw id rather than disappearing.
    private func shortModel(_ id: String) -> String {
        // Strip a provider prefix like "bapi_codex/"
        let bare = id.contains("/") ? String(id.split(separator: "/").last!) : id

        if bare.hasPrefix("claude-") {
            var parts = bare.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // Drop a trailing yyyymmdd snapshot stamp
            if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
            guard let family = parts.first else { return bare }
            let version = parts.dropFirst().joined(separator: ".")
            let name = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? name : "\(name) \(version)"
        }
        if bare.hasPrefix("gpt-") { return "GPT-" + bare.dropFirst(4) }
        return bare
    }

    /// Claude Code's `waitingFor` reason → a short label matching the panel's
    /// other Chinese captions. Unknown reasons pass through as-is.
    private func waitingLabel(_ reason: String) -> String {
        switch reason {
        case "permission prompt": return "待授权"
        case "input needed":      return "待输入"
        case "dialog open":       return "待确认"
        case "sandbox request":   return "沙箱授权"
        case "worker request":    return "子进程请求"
        default:                  return reason
        }
    }

    // MARK: - CPU Panel

    private func renderCPU(_ ctx: CGContext, cpu: CPUSnapshot, temp: TemperatureSnapshot,
                           agentsBusy: Bool) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 20, y: py + 14, font: Fonts.system(24, weight: .bold), color: Color.blue)
        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: cpu.total,
                      color: Color.forPercent(cpu.total),
                      colorDark: Color.forPercentDark(cpu.total), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", cpu.total),
                          cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Per-core bars — E-cores first, then P-cores, shifted down half a row
        let barX = x + 194
        let barW = pw - 218
        let coreCount = cpu.perCore.count
        let bottomLimit = py + ph - 96
        let fontSize: CGFloat = coreCount > 16 ? 12 : (coreCount > 10 ? 14 : 16)
        let barH = coreCount > 16 ? 8 : (coreCount > 10 ? 10 : 10)
        let spacing = min(36, (bottomLimit - py - 18) / max(coreCount, 1))
        let startY = py + 18 + spacing / 2  // shifted down half a row

        let pCoreCount = cpu.pCoreCount
        let eCoreCount = coreCount - pCoreCount

        // Reorder: E-cores first, then P-cores
        for row in 0..<coreCount {
            let by = startY + row * spacing
            if by + Int(fontSize) > bottomLimit { break }

            let coreIndex: Int
            let isECore: Bool
            let label: String
            if row < eCoreCount {
                // E-core rows first
                coreIndex = pCoreCount + row
                isECore = true
                label = "E\(row + 1)"
            } else {
                // P-core rows after
                coreIndex = row - eCoreCount
                isECore = false
                label = "P\(row - eCoreCount + 1)"
            }

            let pct = coreIndex < cpu.perCore.count ? cpu.perCore[coreIndex] : 0
            let barColor = isECore ? Color.cyan : Color.forPercent(pct)

            Draw.text(ctx, label, x: barX, y: by,
                      font: Fonts.system(fontSize), color: isECore ? Color.cyan : Color.textD)
            Draw.bar(ctx, x: barX + 28, y: by + 4, w: barW - 78, h: barH,
                     percent: pct, color: barColor)
            Draw.text(ctx, String(format: "%.0f%%", pct),
                      x: barX + barW - 46, y: by,
                      font: Fonts.system(fontSize), color: Color.textS)
        }

        // Pikachu in the left space below the gauge — its electricity scales with
        // CPU load (the machine's "power draw"). While an AI agent is working it
        // hops and turns to face left/right, like it's cheering the machine on.
        if let pika = PikachuAsset.image {
            let t = Date().timeIntervalSince1970
            let size: CGFloat = 132
            var rect = CGRect(x: CGFloat(x + 100) - size / 2, y: CGFloat(py + 210),
                              width: size, height: size)
            var flip = false
            if agentsBusy {
                let hop = CGFloat(abs(sin(t * .pi * 2)) * 9)   // ~2 hops/sec
                rect.origin.y -= hop                            // up (flipped coords)
                flip = Int(t * 2) % 4 >= 2                       // turn every ~1s
            }
            drawElectricity(ctx, around: rect, intensity: cpu.total, t: t)
            drawImageUpright(ctx, pika, in: rect, flipX: flip)
        }

        // Temp + Load — large, spanning the full panel width at the bottom.
        // Label on the left, value right-aligned to the panel edge.
        let rightEdge = CGFloat(x + pw - 18)
        let tempY = py + ph - 78
        if let cpuTemp = temp.cpuTemp {
            let tempColor = cpuTemp > 65 ? Color.red : (cpuTemp > 50 ? Color.orange : Color.green)
            Draw.text(ctx, "Temp", x: x + 18, y: tempY + 8,
                      font: Fonts.system(26, weight: .medium), color: Color.textL)
            let vStr = String(format: "%.0f°C", cpuTemp)
            let vFont = Fonts.system(42, weight: .bold)
            let vW = (vStr as NSString).size(withAttributes: [.font: vFont]).width
            Draw.text(ctx, vStr, x: Int(rightEdge - vW), y: tempY,
                      font: vFont, color: tempColor)
        }
        let loadY = py + ph - 34
        let (l1, l5, l15) = cpu.loadAvg
        Draw.text(ctx, "Load", x: x + 18, y: loadY,
                  font: Fonts.system(22, weight: .medium), color: Color.textL)
        let lStr = String(format: "%.1f / %.1f / %.1f", l1, l5, l15)
        let lFont = Fonts.system(26, weight: .medium)
        let lW = (lStr as NSString).size(withAttributes: [.font: lFont]).width
        Draw.text(ctx, lStr, x: Int(rightEdge - lW), y: loadY,
                  font: lFont, color: Color.textS)
    }

    /// Yellow lightning crackling around Pikachu — more/brighter bolts as `intensity`
    /// (CPU %) rises. Flickers with `t` so it animates while the frame rate is high.
    private func drawElectricity(_ ctx: CGContext, around rect: CGRect,
                                 intensity: Double, t: Double) {
        let level = min(max(intensity / 100, 0), 1)
        let yellow = CGColor(red: 1.0, green: 0.9, blue: 0.15, alpha: 1)
        let bolts = 2 + Int(level * 6)             // 2…8 bolts
        ctx.setStrokeColor(yellow); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for i in 0..<bolts {
            // Twinkle: each bolt blinks on/off on its own phase
            if (Int(t * 14) + i * 5) % 3 == 0 { continue }
            let ang = Double(i) / Double(bolts) * 2 * .pi + t * 0.7
            let ax = rect.midX + CGFloat(cos(ang)) * rect.width * 0.44
            let ay = rect.midY + CGFloat(sin(ang)) * rect.height * 0.42
            // Jagged 3-segment bolt pointing outward from the anchor
            let len = CGFloat(9 + level * 15)
            let dx = CGFloat(cos(ang)), dy = CGFloat(sin(ang))
            let nx = -dy, ny = dx                  // perpendicular for the zigzag
            ctx.setLineWidth(1.6 + CGFloat(level) * 1.2)
            let jag = 4 + level * 3
            ctx.move(to: CGPoint(x: ax, y: ay))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.4 + nx * CGFloat(jag),
                                    y: ay + dy * len * 0.4 + ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.7 - nx * CGFloat(jag),
                                    y: ay + dy * len * 0.7 - ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len, y: ay + dy * len))
            ctx.strokePath()
        }
    }

    // MARK: - Memory Panel

    private func renderMemory(_ ctx: CGContext, mem: MemorySnapshot, sys: SystemSnapshot?,
                              agentsBusy: Bool) {
        let x = Layout.panelX(4)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let totalGB = Double(mem.total) / (1024 * 1024 * 1024)
        let pct = mem.percent

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.green)
        Draw.text(ctx, "MEMORY", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + pw - 75, y: py + 16,
                  font: Fonts.system(18), color: Color.textD)

        // Arc gauge — length = used% (utilization gauge), COLOR = macOS memory pressure.
        // A Mac using RAM as cache (high used%, low pressure) is healthy → stays green.
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: pct,
                      color: Color.forPressure(mem.pressure),
                      colorDark: Color.forPressureDark(mem.pressure), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", pct), cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Breakdown
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Breakdown", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28

        let activeGB = Double(mem.active) / (1024 * 1024 * 1024)
        let wiredGB = Double(mem.wired) / (1024 * 1024 * 1024)
        let compressedGB = Double(mem.compressed) / (1024 * 1024 * 1024)
        let availGB = Double(mem.available) / (1024 * 1024 * 1024)

        let items: [(String, Double, CGColor)] = [
            ("Active", activeGB, Color.green),
            ("Wired", wiredGB, Color.orange),
            ("Compressed", compressedGB, Color.purple),
            ("Available", availGB, Color.cyan),
        ]
        for (label, val, color) in items {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(17), color: Color.textL)
            let valStr = String(format: "%.1fG", val)
            let valFont = Fonts.system(17)
            let valW = (valStr as NSString).size(withAttributes: [.font: valFont]).width
            Draw.text(ctx, valStr, x: Int(CGFloat(rx + rw) - valW), y: ry,
                      font: valFont, color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: val / totalGB * 100, color: color)
            ry += 48
        }

        // Bottom: a Bongo Cat tapping the divider "table", then the clock below it.
        // (Swap monitoring removed — this space now shows the date/time.)
        let ph = Layout.panelHeight
        let dividerY = py + ph - 116
        let cx0 = x + 16
        let cw = pw - 32
        Draw.line(ctx, from: CGPoint(x: cx0, y: dividerY),
                  to: CGPoint(x: cx0 + cw, y: dividerY), color: Color.border)

        // Bongo cat sits on the left, tapping the divider when an agent is busy
        let t = Date().timeIntervalSince1970
        let tapPhase = Int(t * 5) % 2 == 0
        drawBongoCat(ctx, cx: x + 96, baseY: dividerY, tapping: agentsBusy, phase: tapPhase)

        // Right of the cat: date, weekday, uptime, processes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let ix = x + 190
        formatter.dateFormat = "yyyy-MM-dd"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 196,
                  font: Fonts.system(22, weight: .semibold), color: Color.textW)
        formatter.dateFormat = "EEEE"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 170,
                  font: Fonts.system(16), color: Color.textS)

        let iw = pw - (ix - x) - 16
        func stat(_ label: String, _ value: String, _ sy: Int) {
            Draw.text(ctx, label, x: ix, y: sy, font: Fonts.system(15), color: Color.textL)
            let vf = Fonts.system(15, weight: .medium)
            let vw = (value as NSString).size(withAttributes: [.font: vf]).width
            Draw.text(ctx, value, x: Int(CGFloat(ix + iw) - vw), y: sy, font: vf, color: Color.textS)
        }
        if let sys {
            let h = sys.uptimeSeconds / 3600, m = (sys.uptimeSeconds % 3600) / 60
            let up = h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \(m)m"
            stat("Uptime", up, py + ph - 142)
            stat("Procs", "\(sys.processCount)", py + ph - 120)
        }

        // Clock — big, centered across the full panel width, below the divider
        formatter.dateFormat = "HH:mm:ss"
        Draw.centeredText(ctx, formatter.string(from: Date()),
                          cx: x + pw / 2, y: dividerY + 30,
                          font: Fonts.system(66, weight: .medium), color: Color.textW)
    }

    // MARK: - Bongo Cat (real line-art sprite, kuroni/bongocat-osu)

    /// Draw the classic Bongo Cat: the real line-art head sprite peeking over a desk,
    /// with a keyboard and two pink paws that slap it (`baseY` is the desk line). When
    /// `tapping`, the paws alternate; otherwise they rest and a "z" floats up.
    private func drawBongoCat(_ ctx: CGContext, cx: Int, baseY: Int, tapping: Bool, phase: Bool) {
        let dark = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)
        let pink = CGColor(red: 244/255, green: 150/255, blue: 174/255, alpha: 1)
        let kbTop = CGColor(red: 210/255, green: 216/255, blue: 230/255, alpha: 1)
        let cxD = CGFloat(cx), b = CGFloat(baseY)

        // --- Keyboard on the desk ---
        let kbW: CGFloat = 152, kbH: CGFloat = 15
        let kbX = cxD - kbW / 2, kbY = b - kbH
        let kbPath = CGPath(roundedRect: CGRect(x: kbX, y: kbY, width: kbW, height: kbH),
                            cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(kbTop); ctx.addPath(kbPath); ctx.fillPath()
        ctx.setStrokeColor(dark); ctx.setLineWidth(1.5); ctx.addPath(kbPath); ctx.strokePath()
        ctx.setLineWidth(1)
        var kx = kbX + 13
        while kx < kbX + kbW - 6 {
            ctx.move(to: CGPoint(x: kx, y: kbY + 2)); ctx.addLine(to: CGPoint(x: kx, y: kbY + kbH - 2))
            kx += 13
        }
        ctx.strokePath()

        // --- Cat head sprite, chin just above the keyboard ---
        if let cat = BongoCatAsset.image {
            let cw: CGFloat = 148
            let ch = cw * CGFloat(cat.height) / CGFloat(cat.width)
            let rect = CGRect(x: cxD - cw / 2, y: kbY - 4 - ch, width: cw, height: ch)
            drawImageUpright(ctx, cat, in: rect)
        }

        // --- Pink paws resting on / slapping the keyboard, outlined to match line art ---
        let pawRX: CGFloat = 13, pawRY: CGFloat = 10
        let downY = kbY + 2, upY = kbY - 14         // down = on keys, up = lifted to tap
        let lY = tapping ? (phase ? upY : downY) : downY
        let rY = tapping ? (phase ? downY : upY) : downY
        for (px, py2) in [(cxD - 34, lY), (cxD + 34, rY)] {
            let r = CGRect(x: px - pawRX, y: py2 - pawRY, width: pawRX * 2, height: pawRY * 2)
            ctx.setFillColor(pink); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(dark); ctx.setLineWidth(2); ctx.strokeEllipse(in: r)
        }

        // Zzz when dozing
        if !tapping {
            Draw.text(ctx, "z", x: Int(cxD) + 60, y: Int(kbY) - 74,
                      font: Fonts.system(16, weight: .bold), color: Color.textL)
            Draw.text(ctx, "z", x: Int(cxD) + 72, y: Int(kbY) - 88,
                      font: Fonts.system(12, weight: .bold), color: Color.textD)
        }
    }

    /// Draw a CGImage upright inside `rect` within the flipped (y-down) context.
    /// `flipX` mirrors it horizontally (for facing left/right).
    private func drawImageUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect,
                                 flipX: Bool = false) {
        ctx.saveGState()
        if flipX {
            ctx.translateBy(x: rect.maxX, y: rect.minY + rect.height)
            ctx.scaleBy(x: -1, y: -1)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - AI Agents Panel (triple width)

    private func renderAgents(_ ctx: CGContext, agents: AgentsSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth * 3 + Layout.gap * 2
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.purple)
        Draw.text(ctx, "AI AGENTS", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.purple)

        // Vertical divider between columns
        let midX = x + pw / 2
        Draw.line(ctx, from: CGPoint(x: midX, y: py + 52),
                  to: CGPoint(x: midX, y: py + ph - 14), color: Color.border)

        let colW = pw / 2 - 40
        let left = AgentKind.left
        let right = AgentKind.right
        renderAgentColumn(ctx, x: x + 22, w: colW, py: py,
                          name: left.columnName, accent: accentColor(for: left),
                          usage: agents.usage(for: left))
        renderAgentColumn(ctx, x: midX + 18, w: colW, py: py,
                          name: right.columnName, accent: accentColor(for: right),
                          usage: agents.usage(for: right))
    }

    private func accentColor(for kind: AgentKind) -> CGColor {
        switch kind {
        case .claude: return Color.claude
        case .codex:  return Color.cyan
        case .cursor: return Color.cursor
        }
    }

    private func renderAgentColumn(_ ctx: CGContext, x: Int, w: Int, py: Int,
                                   name: String, accent: CGColor, usage: AgentUsage) {
        let ph = Layout.panelHeight

        // Column background — three states, agent-tinted:
        //   needsAttention (done / waiting) → hard on/off blink (high-contrast alert)
        //   isWorking      (running a turn)  → slow, gentle breathing (~5s period)
        //   idle                            → static tint
        // render() runs every 0.5s, smooth enough for both sin() and the blink.
        let bgRect = CGRect(x: CGFloat(x - 12), y: CGFloat(py + 42),
                            width: CGFloat(w + 24), height: CGFloat(ph - 56))
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 12, cornerHeight: 12,
                            transform: nil)
        // Claude's terracotta needs a hair more base alpha to read on the dark panel
        let base: CGFloat = name == "CLAUDE" ? 0.09 : 0.08
        let t = Date().timeIntervalSince1970
        let blinkOn = Int(t * 2) % 2 == 0
        // Linear triangle breathing (0→1→0 over 5s). A constant per-frame delta reads
        // far smoother than cosine easing at the display's low frame rate — no stutter
        // where the cosine flattens near its peaks/troughs.
        let phase = t.truncatingRemainder(dividingBy: 5) / 5        // 0..1
        let breath = CGFloat(phase < 0.5 ? phase * 2 : (1 - phase) * 2)
        var bgAlpha = base
        if usage.needsAttention {
            bgAlpha = blinkOn ? 0.36 : 0.10
        } else if usage.isWorking {
            bgAlpha = base + 0.13 * breath
        }
        ctx.setFillColor(accent.copy(alpha: bgAlpha) ?? accent)
        ctx.addPath(bgPath)
        ctx.fillPath()
        if usage.needsAttention {
            ctx.setStrokeColor(accent.copy(alpha: blinkOn ? 0.9 : 0.25) ?? accent)
            ctx.setLineWidth(2)
            ctx.addPath(bgPath)
            ctx.strokePath()
        } else if usage.isWorking {
            // Faint breathing border to reinforce the "alive/working" feel
            ctx.setStrokeColor(accent.copy(alpha: 0.12 + 0.28 * breath) ?? accent)
            ctx.setLineWidth(1.5)
            ctx.addPath(bgPath)
            ctx.strokePath()
        }

        // Header: name + activity indicator (right-aligned "● now" / "12m ago")
        Draw.text(ctx, name, x: x, y: py + 50,
                  font: Fonts.system(24, weight: .bold), color: accent)
        let active = (usage.secondsSinceActive ?? Int.max) < 90
        let agoStr: String
        if !usage.available {
            agoStr = "not found"
        } else if let s = usage.secondsSinceActive {
            agoStr = active ? "now"
                : (s < 3600 ? "\(s / 60)m ago"
                   : (s < 86400 ? "\(s / 3600)h ago" : "\(s / 86400)d ago"))
        } else {
            agoStr = "no session"
        }
        let agoFont = Fonts.system(17, weight: .medium)
        let agoColor = active ? Color.green : Color.textD
        let agoW = (agoStr as NSString).size(withAttributes: [.font: agoFont]).width
        Draw.text(ctx, agoStr, x: Int(CGFloat(x + w) - agoW), y: py + 56,
                  font: agoFont, color: agoColor)
        let dotR: CGFloat = 5
        ctx.setFillColor(agoColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(x + w) - agoW - dotR * 2 - 8,
                                   y: CGFloat(py + 56) + 10 - dotR,
                                   width: dotR * 2, height: dotR * 2))

        // Header extras, laid out left to right after the column name: the active
        // model, then the blocked-on-you badge. A shared cursor keeps them from
        // overlapping, and each is dropped rather than drawn if it would run into
        // the right-aligned ago text.
        let nameW = (name as NSString)
            .size(withAttributes: [.font: Fonts.system(24, weight: .bold)]).width
        var cursor = CGFloat(x) + nameW + 14
        let rightLimit = CGFloat(x + w) - agoW - 24

        if let id = usage.model {
            let label = shortModel(id)
            let mFont = Fonts.system(16, weight: .medium)
            let mW = (label as NSString).size(withAttributes: [.font: mFont]).width
            if cursor + mW < rightLimit {
                Draw.text(ctx, label, x: Int(cursor), y: py + 56,
                          font: mFont, color: Color.textL)
                cursor += mW + 12
            }
        }

        // Solid amber so the badge stays legible through the attention blink.
        if let reason = usage.waitingFor {
            let label = waitingLabel(reason)
            let bFont = Fonts.system(16, weight: .bold)
            let bW = (label as NSString).size(withAttributes: [.font: bFont]).width
            let padX: CGFloat = 9, padY: CGFloat = 4
            let by = CGFloat(py + 50) + 3
            if cursor + bW + padX * 2 < rightLimit {
                let pill = CGRect(x: cursor, y: by, width: bW + padX * 2,
                                  height: bFont.pointSize + padY * 2)
                ctx.setFillColor(Color.orange)
                ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5,
                                   transform: nil))
                ctx.fillPath()
                Draw.text(ctx, label, x: Int(cursor + padX), y: Int(by + padY - 1),
                          font: bFont, color: Color.bgTop)
            }
        }

        // Current session — TOP. Project (+ step badge), plan progress, live activity.
        var y = py + 90
        if let project = usage.project {
            // Step badge "步骤 4/6" right-aligned on the project line, when a plan exists
            var projMaxW = CGFloat(w)
            if let cur = usage.stepCurrent, let total = usage.stepTotal {
                let badge = "步骤 \(cur)/\(total)"
                let bFont = Fonts.system(18, weight: .semibold)
                let bW = (badge as NSString).size(withAttributes: [.font: bFont]).width
                Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: y + 4,
                          font: bFont, color: accent)
                projMaxW = CGFloat(w) - bW - 16
            }
            Draw.text(ctx, truncate(project, font: Fonts.system(26, weight: .semibold),
                                    maxW: projMaxW),
                      x: x, y: y, font: Fonts.system(26, weight: .semibold), color: Color.textW)
            y += 38
        }

        // Plan progress — compact segmented bar (the badge conveys N/M; no text line,
        // so the message below gets the room)
        if let cur = usage.stepCurrent, let total = usage.stepTotal, total > 0 {
            drawStepBar(ctx, x: x, y: y, w: w, current: cur, total: total, accent: accent)
            y += 20
        }

        // Latest message — what the agent last said (never the commands it ran).
        // Markdown tables/lists are laid out structurally; plain text just wraps.
        let actText = usage.activity ?? (usage.available ? "空闲" : "—")
        let msgBottom = py + ph - 140   // token divider sits here
        renderMessage(ctx, text: actText, x: x, y: y, w: w, bottom: msgBottom, accent: accent)

        // Token usage — large, anchored near the bottom of the column
        let tokY = py + ph - 126
        Draw.line(ctx, from: CGPoint(x: x, y: tokY - 12),
                  to: CGPoint(x: x + w, y: tokY - 12), color: Color.border)
        Draw.text(ctx, "今日 Token", x: x, y: tokY,
                  font: Fonts.system(19), color: Color.textL)
        if usage.hasTokenUsage {
            Draw.text(ctx, formatTokensCN(usage.todayTotalTokens), x: x, y: tokY + 24,
                      font: Fonts.system(46, weight: .bold), color: Color.textW)

            // In / Out — right-aligned, level with the label + big number
            let ioFont = Fonts.system(20, weight: .medium)
            let ioRows: [(String, UInt64)] = [
                ("In", usage.todayInputTokens),
                ("Out", usage.todayOutputTokens),
            ]
            for (i, row) in ioRows.enumerated() {
                let ry = tokY + 6 + i * 30
                let valStr = formatTokensCN(row.1)
                let valW = (valStr as NSString).size(withAttributes: [.font: ioFont]).width
                Draw.text(ctx, valStr, x: Int(CGFloat(x + w) - valW), y: ry,
                          font: ioFont, color: Color.textS)
                let labelW = (row.0 as NSString).size(withAttributes: [.font: ioFont]).width
                Draw.text(ctx, row.0, x: Int(CGFloat(x + w) - valW - labelW - 10), y: ry,
                          font: ioFont, color: Color.textL)
            }
        } else {
            // Cursor (and any future source) never writes per-message usage
            Draw.text(ctx, "—", x: x, y: tokY + 24,
                      font: Fonts.system(46, weight: .bold), color: Color.textD)
            Draw.text(ctx, "无日用量 · 见上下文", x: x + 70, y: tokY + 42,
                      font: Fonts.system(17), color: Color.textL)
        }

        // Bottom bar: Codex remaining quota, or Cursor context-window fill.
        // `quotaUsedPercent` is "used" in both cases; Codex flips it to remaining.
        if let used = usage.quotaUsedPercent {
            let qy = tokY + 78
            if usage.hasTokenUsage {
                // Codex subscription window — show remaining
                let remaining = max(0, 100 - used)
                let qColor: CGColor = remaining > 50 ? Color.green
                    : (remaining > 20 ? Color.orange : Color.red)
                Draw.text(ctx, String(format: "剩余额度 %.0f%%", remaining), x: x, y: qy,
                          font: Fonts.system(21, weight: .medium), color: qColor)
                if let resets = usage.quotaResetsAt {
                    let secs = max(0, Int(resets.timeIntervalSinceNow))
                    let resetStr = secs >= 86400 ? "\(secs / 86400)天后重置"
                        : (secs >= 3600 ? "\(secs / 3600)小时后重置"
                           : "\(max(secs / 60, 1))分钟后重置")
                    let rFont = Fonts.system(17)
                    let rW = (resetStr as NSString).size(withAttributes: [.font: rFont]).width
                    Draw.text(ctx, resetStr, x: Int(CGFloat(x + w) - rW), y: qy + 3,
                              font: rFont, color: Color.textD)
                }
                Draw.bar(ctx, x: x, y: qy + 28, w: w, h: 8,
                         percent: remaining, color: qColor)
            } else {
                // Cursor — context window fill of the active chat (not a daily total)
                let fill = min(max(used, 0), 100)
                let qColor: CGColor = fill < 50 ? Color.cursor
                    : (fill < 80 ? Color.orange : Color.red)
                Draw.text(ctx, String(format: "上下文 %.0f%%", fill), x: x, y: qy,
                          font: Fonts.system(21, weight: .medium), color: qColor)
                Draw.bar(ctx, x: x, y: qy + 28, w: w, h: 8,
                         percent: fill, color: qColor)
            }
        }
    }

    /// Segmented plan-progress bar: completed steps solid, current bright, pending dim.
    private func drawStepBar(_ ctx: CGContext, x: Int, y: Int, w: Int,
                             current: Int, total: Int, accent: CGColor) {
        guard total > 0 else { return }
        let gap = 4
        let segW = (w - gap * (total - 1)) / total
        guard segW > 0 else { return }
        for i in 0..<total {
            let sx = x + i * (segW + gap)
            let color: CGColor
            if i < current - 1 {          // completed
                color = accent.copy(alpha: 0.5) ?? accent
            } else if i == current - 1 {  // current
                color = accent
            } else {                      // pending
                color = Color.barBG
            }
            let rect = CGRect(x: CGFloat(sx), y: CGFloat(y), width: CGFloat(segW), height: 7)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
    }

    /// 中文数量格式："33.99万"、"1.02亿"。1万以下显示原始数字。
    private func formatTokensCN(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1e8 {
            let y = v / 1e8
            return String(format: y < 100 ? "%.2f亿" : "%.1f亿", y)
        }
        if v >= 1e4 {
            let w = v / 1e4
            return String(format: w < 100 ? "%.2f万" : (w < 1000 ? "%.1f万" : "%.0f万"), w)
        }
        return "\(n)"
    }

    // MARK: - Agent message layout (markdown-aware)

    /// Render an agent message top-down within [y, bottom): markdown tables become
    /// aligned grids, `- ` bullets and prose wrap. Stops when vertical space runs out.
    private func renderMessage(_ ctx: CGContext, text: String, x: Int, y: Int, w: Int,
                               bottom: Int, accent: CGColor) {
        let proseFont = Fonts.system(19)
        let lineH = 26
        var cy = y
        // Trim once up front: this runs every frame, and the loop below used to
        // re-trim the same lines several times over.
        let raw = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // reserve[j] = lines the blocks from j onward need at minimum, so a long
        // paragraph can be told how much room it must leave for its successors.
        // Table rows want one line each; anything else gets the 2-line floor every
        // prose block is guaranteed. Computed as a suffix sum so the layout stays
        // linear in the number of lines.
        var reserve = [Int](repeating: 0, count: raw.count + 1)
        for j in stride(from: raw.count - 1, through: 0, by: -1) {
            let cost = raw[j].isEmpty ? 0 : (isTableLine(raw[j]) ? 1 : 2)
            reserve[j] = reserve[j + 1] + cost
        }

        var i = 0
        while i < raw.count && cy + 20 <= bottom {
            let line = raw[i]
            if line.isEmpty { i += 1; continue }

            if isTableLine(line) {
                // Consume the contiguous run of table rows and render as a grid
                var block: [String] = []
                while i < raw.count && isTableLine(raw[i]) {
                    block.append(raw[i])
                    i += 1
                }
                cy = renderTable(ctx, rows: block, x: x, y: cy, w: w, bottom: bottom, accent: accent)
            } else {
                // Prose / bullet — wrap, capped so this block cannot crowd out what
                // follows (typically a markdown table). Budget against what actually
                // comes next rather than a flat 2 lines: an agent mid-turn usually
                // writes one long unbroken paragraph, and the flat cap rendered two
                // lines of it and left the rest of the column blank. With nothing
                // after it, a paragraph may use the whole panel.
                let remaining = (bottom - cy) / lineH
                guard remaining > 0 else { break }
                let cap = max(2, remaining - reserve[i + 1])
                let wrapped = wrap(stripMarkdown(line), font: proseFont,
                                   maxW: CGFloat(w), maxLines: min(cap, remaining))
                for wl in wrapped {
                    if cy + lineH > bottom { break }
                    Draw.text(ctx, wl, x: x, y: cy, font: proseFont, color: Color.textS)
                    cy += lineH
                }
                i += 1
            }
        }
    }

    private func isTableLine(_ s: String) -> Bool {
        s.hasPrefix("|") && s.filter { $0 == "|" }.count >= 2
    }

    /// A markdown separator cell like `---`, `:--`, `--:`, `:-:`.
    private func isSeparatorCell(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
    }

    private func stripMarkdown(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
        // Drop leading ATX heading markers ("## 标题" → "标题")
        if t.hasPrefix("#") {
            t = String(t.drop(while: { $0 == "#" || $0 == " " }))
        }
        return t
    }

    /// Render markdown table rows as an aligned grid. Returns the new y below it.
    private func renderTable(_ ctx: CGContext, rows rawRows: [String], x: Int, y: Int,
                             w: Int, bottom: Int, accent: CGColor) -> Int {
        // Parse into cell rows, dropping the separator row and empty edge cells
        var rows: [[String]] = []
        for line in rawRows {
            var cells = line.components(separatedBy: "|").map {
                stripMarkdown($0.trimmingCharacters(in: .whitespaces))
            }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            if cells.allSatisfy({ isSeparatorCell($0) }) { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return y }

        let cols = rows.map(\.count).max() ?? 1
        let rowH = 24
        let colGap = 8
        let colW = (w - colGap * (cols - 1)) / max(cols, 1)
        guard colW > 20 else { return y }
        let cellFont = Fonts.system(16)
        let headFont = Fonts.system(16, weight: .semibold)

        var cy = y + 2
        for (ri, row) in rows.enumerated() {
            if cy + rowH > bottom { break }
            for ci in 0..<cols {
                let cell = ci < row.count ? row[ci] : ""
                if cell.isEmpty { continue }
                let cx = x + ci * (colW + colGap)
                let font = ri == 0 ? headFont : cellFont
                let color = ri == 0 ? accent : Color.textS
                Draw.text(ctx, truncate(cell, font: font, maxW: CGFloat(colW)),
                          x: cx, y: cy, font: font, color: color)
            }
            cy += rowH
            if ri == 0 {  // underline under the header row
                Draw.line(ctx, from: CGPoint(x: x, y: cy - 4),
                          to: CGPoint(x: x + w, y: cy - 4), color: Color.border)
            }
        }
        return cy + 4
    }

    /// Truncate a single line with "…" to fit maxW.
    private func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if ((t + "…") as NSString).size(withAttributes: attrs).width <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    private func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > maxW {
                // Reached the last allowed line → fold the whole remainder into it
                if lines.count == maxLines - 1 {
                    let rest = String(s[s.index(s.startIndex, offsetBy: lines.joined().count)...])
                    lines.append(truncate(rest, font: font, maxW: maxW))
                    return lines
                }
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

}
