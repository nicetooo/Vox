import AppKit

// MARK: - Custom Panel (borderless, can become key for search input)

private class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Dark Table Row View

private class DarkRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)

        // Brighter gray fill — needs strong contrast vs the 0.13 panel background.
        NSColor(white: 0.28, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        // 3px blue accent strip on the left so it's unmistakable.
        let accent = NSRect(x: rect.minX + 1, y: rect.minY + 6, width: 3, height: rect.height - 12)
        NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: accent, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) { /* transparent */ }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .emphasized }
}

// MARK: - Pill Toggle (date filter)

private class PillToggle: NSView {
    private var title: String
    private(set) var isOn: Bool
    var index: Int = 0
    var onClick: ((Int) -> Void)?

    init(title: String, selected: Bool = false) {
        self.title = title
        self.isOn = selected
        super.init(frame: .zero)
        wantsLayer = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool) {
        isOn = on
        updateColors()
        needsDisplay = true
    }
    private func updateColors() {
        layer?.cornerRadius = 13
        layer?.backgroundColor = isOn
            ? NSColor.white.cgColor
            : NSColor(white: 0.20, alpha: 1.0).cgColor
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor = isOn ? .black : NSColor(white: 0.55, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let s = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                               y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Action Button (dark themed)

private class DarkActionButton: NSView {
    private var title: String
    private let isDestructive: Bool
    var onClick: (() -> Void)?

    init(title: String, destructive: Bool = false) {
        self.title = title
        self.isDestructive = destructive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.20, alpha: 1.0).cgColor
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateTitle(_ t: String) { title = t; needsDisplay = true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.32, alpha: 1.0).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.20, alpha: 1.0).cgColor
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor = isDestructive
            ? NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
            : .white
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let s = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                               y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

// MARK: - History Window Controller

class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var panel: HistoryPanel?
    private var tableView: NSTableView?
    private var searchField: NSSearchField?
    private var countLabel: NSTextField?
    private var emptyLabel: NSTextField?
    private var records: [HistoryRecord] = []
    private var expandedRow: Int? = nil
    private var localKeyMonitor: Any?
    private var typeFilterIndex = 0
    private var typeButtons: [PillToggle] = []
    private var copyBtn: DarkActionButton?

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Toggle / Show / Hide

    func toggleHistory() {
        if let p = panel, p.isVisible { hideHistory(); return }
        showHistory()
    }

    func showHistory() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            reloadData()
            return
        }

        let w: CGFloat = 520, h: CGFloat = 480

        let p = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = buildContent(w, h)
        p.center()

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = p

        setupKeyMonitor()
        reloadData()
    }

    func hideHistory() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
        typeButtons = []
        expandedRow = nil
        // Reset filter state too — next open rebuilds pills with "All" highlighted
        // (selected: i == 0 hardcoded in buildContent), so the state must match.
        typeFilterIndex = 0
    }

    func windowWillClose(_ n: Notification) {
        removeKeyMonitor()
        panel = nil
        typeButtons = []
        expandedRow = nil
        typeFilterIndex = 0
    }

    // MARK: - ESC to close

    private func setupKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hideHistory()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    // MARK: - Build UI

    private func buildContent(_ width: CGFloat, _ height: CGFloat) -> NSView {
        let pad: CGFloat = 18

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.appearance = NSAppearance(named: .darkAqua)

        // --- Title ---
        let title = NSTextField(labelWithString: "History")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        // --- Hint ---
        let hint = NSTextField(labelWithString: "ESC to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.35, alpha: 1.0)
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hint)

        // --- Search ---
        let search = NSSearchField()
        search.placeholderString = "Search..."
        search.delegate = self
        search.font = .systemFont(ofSize: 13)
        search.focusRingType = .none
        search.translatesAutoresizingMaskIntoConstraints = false
        self.searchField = search
        root.addSubview(search)

        // --- Type filter pills ---
        let pillStack = NSStackView()
        pillStack.orientation = .horizontal
        pillStack.spacing = 6
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        typeButtons = []

        for (i, label) in ["All", "Voice", "Translation", "Screenshot"].enumerated() {
            let pill = PillToggle(title: label, selected: i == 0)
            pill.index = i
            pill.onClick = { [weak self] tag in self?.typeFilterTapped(tag) }
            pill.translatesAutoresizingMaskIntoConstraints = false
            let tw = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            pill.widthAnchor.constraint(equalToConstant: tw + 24).isActive = true
            pill.heightAnchor.constraint(equalToConstant: 26).isActive = true
            pillStack.addArrangedSubview(pill)
            typeButtons.append(pill)
        }
        root.addSubview(pillStack)

        // --- Table scroll area ---
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1.0).cgColor

        let table = NSTableView()
        table.style = .plain
        table.rowSizeStyle = .custom
        // .regular keeps AppKit calling drawSelection on the row view; our DarkRowView
        // overrides drawSelection to paint our own highlight (not the system blue).
        // Setting .none here would skip the callback entirely and selection becomes invisible.
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 0)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        scroll.documentView = table
        self.tableView = table
        root.addSubview(scroll)

        // --- Empty state ---
        let empty = NSTextField(labelWithString: "No history yet")
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = NSColor(white: 0.4, alpha: 1.0)
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        self.emptyLabel = empty
        root.addSubview(empty)

        // --- Bottom bar ---
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let cBtn = DarkActionButton(title: "Copy")
        cBtn.onClick = { [weak self] in self?.copySelectedToClipboard() }
        cBtn.translatesAutoresizingMaskIntoConstraints = false
        self.copyBtn = cBtn
        bar.addSubview(cBtn)

        let delBtn = DarkActionButton(title: "Delete", destructive: true)
        delBtn.onClick = { [weak self] in self?.deleteClicked() }
        delBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(delBtn)

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor(white: 0.45, alpha: 1.0)
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        self.countLabel = count
        bar.addSubview(count)

        let clearBtn = DarkActionButton(title: "Clear All", destructive: true)
        clearBtn.onClick = { [weak self] in self?.clearAllClicked() }
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(clearBtn)

        root.addSubview(bar)

        // --- Constraints ---
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),

            hint.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            search.heightAnchor.constraint(equalToConstant: 28),

            pillStack.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            pillStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),

            scroll.topAnchor.constraint(equalTo: pillStack.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 30),

            cBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            cBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cBtn.widthAnchor.constraint(equalToConstant: 60),
            cBtn.heightAnchor.constraint(equalToConstant: 28),

            delBtn.leadingAnchor.constraint(equalTo: cBtn.trailingAnchor, constant: 8),
            delBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 64),
            delBtn.heightAnchor.constraint(equalToConstant: 28),

            clearBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            clearBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 72),
            clearBtn.heightAnchor.constraint(equalToConstant: 28),

            count.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return root
    }

    // MARK: - Data

    private func typeFilterTapped(_ index: Int) {
        typeFilterIndex = index
        for (i, btn) in typeButtons.enumerated() { btn.setSelected(i == index) }
        reloadData()
    }

    private func reloadData() {
        let query = searchField?.stringValue
        let filter = HistoryTypeFilter(rawValue: typeFilterIndex) ?? .all
        records = HistoryStore.shared.fetch(query: query, typeFilter: filter)
        expandedRow = nil
        tableView?.reloadData()
        countLabel?.stringValue = "\(records.count) items"
        emptyLabel?.isHidden = !records.isEmpty
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return records.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return DarkRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let isExpanded = (row == expandedRow)
        if !isExpanded { return 50 }

        guard row < records.count else { return 50 }
        let record = records[row]
        let tableWidth = tableView.bounds.width

        // Screenshot: expanded row shows the image scaled to fit (cap 240px tall).
        if record.type == .screenshot {
            let availW = max(tableWidth - 60, 200)
            if let path = record.imagePath, let img = NSImage(contentsOfFile: path), img.size.width > 0 {
                let aspect = img.size.height / img.size.width
                let fitH = min(availW * aspect, 240)
                return 50 + fitH + 16  // header row + image + bottom pad
            }
            return 80  // file missing fallback
        }

        let textWidth = max(tableWidth - 170, 200)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let rect = (record.displayText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(rect.height + 34, 50)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < records.count else { return nil }
        let record = records[row]
        let isExpanded = (row == expandedRow)

        let cell = NSView()

        // --- Type icon (SF Symbol) ---
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let symbolName: String
        let tint: NSColor
        switch record.type {
        case .voice:
            symbolName = "mic.fill"
            tint = NSColor(red: 0.35, green: 0.82, blue: 0.45, alpha: 1.0)  // green
        case .translation:
            symbolName = "arrow.left.arrow.right"
            tint = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)   // blue
        case .screenshot:
            symbolName = "photo.fill"
            tint = NSColor(red: 1.0, green: 0.70, blue: 0.30, alpha: 1.0)   // orange
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = tint
        cell.addSubview(iconView)

        // --- Text ---
        let text = NSTextField(wrappingLabelWithString: record.displayText)
        text.font = .systemFont(ofSize: 13)
        text.textColor = .white
        text.drawsBackground = false
        text.isBordered = false
        text.isSelectable = false
        text.translatesAutoresizingMaskIntoConstraints = false
        if isExpanded && record.type != .screenshot {
            text.lineBreakMode = .byWordWrapping
            text.maximumNumberOfLines = 0
        } else {
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = isExpanded ? 1 : 2
            text.cell?.truncatesLastVisibleLine = true
        }
        cell.addSubview(text)

        // --- Timestamp ---
        let time = NSTextField(labelWithString: timeFormatter.string(from: record.timestamp))
        time.font = .systemFont(ofSize: 11)
        time.textColor = NSColor(white: 0.45, alpha: 1.0)
        time.alignment = .right
        time.translatesAutoresizingMaskIntoConstraints = false
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(time)

        // --- Separator line ---
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.20, alpha: 0.6).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(sep)

        // Vertical alignment strategy: anchor everything to the text's first-line baseline,
        // which is the typographically correct way to align text with text. The icon is a
        // 20×20 SF Symbol view — we align its visual center (centerY) to ~5px above the
        // text baseline so the symbol's cap-mid lines up with the text's cap-mid.
        // text.top = 16 visually centers a single line in a 50px row (Chinese caps included).
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -5),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 16),

            time.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            time.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            time.widthAnchor.constraint(lessThanOrEqualToConstant: 110),

            sep.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 44),
            sep.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // --- Screenshot expanded preview ---
        if isExpanded && record.type == .screenshot {
            let preview = NSImageView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.imageAlignment = .alignTopLeft
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 6
            preview.layer?.masksToBounds = true
            preview.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1.0).cgColor

            if let path = record.imagePath, let img = NSImage(contentsOfFile: path) {
                preview.image = img
            }
            cell.addSubview(preview)

            // Place preview below the text row, full width inside cell padding.
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 44),
                preview.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                preview.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 8),
                preview.bottomAnchor.constraint(equalTo: sep.topAnchor, constant: -8),
            ])

            // "File missing" overlay if image failed to load.
            if preview.image == nil {
                let missing = NSTextField(labelWithString: "File missing on disk")
                missing.font = .systemFont(ofSize: 12)
                missing.textColor = NSColor(white: 0.55, alpha: 1.0)
                missing.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(missing)
                NSLayoutConstraint.activate([
                    missing.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
                    missing.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
                ])
            }
        } else {
            text.bottomAnchor.constraint(lessThanOrEqualTo: sep.topAnchor, constant: -10).isActive = true
        }

        return cell
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        guard let table = tableView else { return }
        let clicked = table.clickedRow
        guard clicked >= 0, clicked < records.count else { return }

        var rowsToUpdate = IndexSet()

        // Collapse previous expanded row
        if let prev = expandedRow {
            rowsToUpdate.insert(prev)
        }

        // Toggle: click same row collapses, click different expands new
        if expandedRow == clicked {
            expandedRow = nil
        } else {
            expandedRow = clicked
        }
        rowsToUpdate.insert(clicked)

        // Reload cells and animate height change
        table.reloadData(forRowIndexes: rowsToUpdate, columnIndexes: IndexSet(integer: 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            table.noteHeightOfRows(withIndexesChanged: rowsToUpdate)
        }

        // Sync selection to expanded row (for visual highlight + copy/delete)
        if let exp = expandedRow {
            table.selectRowIndexes(IndexSet(integer: exp), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    @objc private func rowDoubleClicked() {
        copySelectedToClipboard()
    }

    private func deleteClicked() {
        let selected = tableView?.selectedRowIndexes ?? IndexSet()
        guard !selected.isEmpty else { return }
        let ids = selected.compactMap { idx -> Int64? in
            guard idx < records.count else { return nil }
            return records[idx].id
        }
        for id in ids { HistoryStore.shared.delete(id: id) }
        reloadData()
    }

    private func clearAllClicked() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all \(records.count) records."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.deleteAll()
        reloadData()
    }

    private func copySelectedToClipboard() {
        let selected = tableView?.selectedRowIndexes ?? IndexSet()
        guard !selected.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        var copiedLabel = "Copied!"

        // Single-screenshot selection: put the image on the clipboard so it can be
        // pasted into chat / mail / docs. (Selection is single-only by config.)
        if selected.count == 1,
           let idx = selected.first,
           idx < records.count,
           records[idx].type == .screenshot,
           let path = records[idx].imagePath {
            if let img = NSImage(contentsOfFile: path) {
                pb.writeObjects([img])
                log("History: copied screenshot \(path)")
            } else {
                copiedLabel = "File missing"
                log("History: screenshot file missing — \(path)")
            }
        } else {
            // Text records: join their copyText.
            let texts = selected.compactMap { idx -> String? in
                guard idx < records.count else { return nil }
                let r = records[idx]
                return r.type == .screenshot ? nil : r.copyText  // skip screenshots in mixed selection
            }
            pb.setString(texts.joined(separator: "\n"), forType: .string)
            log("History: copied \(texts.count) items")
        }

        countLabel?.stringValue = copiedLabel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.countLabel?.stringValue = "\(self?.records.count ?? 0) items"
        }
    }
}
