import AppKit

// MARK: - History Window Controller

class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var searchField: NSSearchField?
    private var dateFilter: NSPopUpButton?
    private var countLabel: NSTextField?
    private var records: [HistoryRecord] = []
    private var expandedRows = IndexSet()       // tracks which rows show full text
    private var isUpdatingSelection = false

    private static let cellID = NSUserInterfaceItemIdentifier("HistoryCell")

    // MARK: - Time Formatter

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Show Window

    func showHistory() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            reloadData()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "History"
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 400, height: 300)
        w.contentView = buildContent()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w

        reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Build Content

    private func buildContent() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 520))

        // === Top bar: Search + Date filter ===
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "Search history..."
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        self.searchField = search
        topBar.addArrangedSubview(search)

        let datePop = NSPopUpButton(frame: .zero, pullsDown: false)
        datePop.addItem(withTitle: "All Time")
        datePop.addItem(withTitle: "Today")
        datePop.addItem(withTitle: "Last 7 Days")
        datePop.addItem(withTitle: "Last 30 Days")
        datePop.target = self
        datePop.action = #selector(dateFilterChanged)
        datePop.translatesAutoresizingMaskIntoConstraints = false
        datePop.widthAnchor.constraint(equalToConstant: 130).isActive = true
        self.dateFilter = datePop
        topBar.addArrangedSubview(datePop)

        container.addSubview(topBar)

        // === Table view ===
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.style = .plain
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.headerView = nil  // no header

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        self.tableView = table
        container.addSubview(scrollView)

        // === Bottom bar: buttons + count ===
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = makeButton("Copy", action: #selector(copyClicked))
        let deleteBtn = makeButton("Delete", action: #selector(deleteClicked))
        deleteBtn.contentTintColor = .systemRed

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let count = NSTextField(labelWithString: "")
        count.font = NSFont.systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        self.countLabel = count

        let clearBtn = makeButton("Clear All", action: #selector(clearAllClicked))
        clearBtn.contentTintColor = .systemRed

        bottomBar.addArrangedSubview(copyBtn)
        bottomBar.addArrangedSubview(deleteBtn)
        bottomBar.addArrangedSubview(spacer)
        bottomBar.addArrangedSubview(count)
        bottomBar.addArrangedSubview(clearBtn)

        container.addSubview(bottomBar)

        // === Layout ===
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 0),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            bottomBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        return container
    }

    // MARK: - Data

    private func reloadData() {
        let query = searchField?.stringValue
        let filterIdx = dateFilter?.indexOfSelectedItem ?? 0
        let filter = HistoryDateFilter(rawValue: filterIdx) ?? .allTime
        records = HistoryStore.shared.fetch(query: query, dateFilter: filter)
        tableView?.reloadData()
        countLabel?.stringValue = "\(records.count) items"
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return records.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let isExpanded = expandedRows.contains(row)
        if !isExpanded { return 52 }

        // Calculate height for full text
        guard row < records.count else { return 52 }
        let record = records[row]
        let displayText = record.displayText

        let tableWidth = tableView.bounds.width
        let textWidth = max(tableWidth - 190, 200)

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let boundingRect = (displayText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(boundingRect.height + 28, 52)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        guard let table = tableView else { return }

        let currentSelection = table.selectedRowIndexes
        let changed = expandedRows.symmetricDifference(currentSelection)
        expandedRows = currentSelection

        guard !changed.isEmpty else { return }

        isUpdatingSelection = true

        // Reload changed rows so viewFor recreates cells with correct text wrapping
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))

        // Update row heights
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            table.noteHeightOfRows(withIndexesChanged: changed)
        }

        // Restore selection (reloadData may have cleared it)
        table.selectRowIndexes(currentSelection, byExtendingSelection: false)

        isUpdatingSelection = false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < records.count else { return nil }
        let record = records[row]
        let isExpanded = expandedRows.contains(row)

        let cell = NSView()

        // Icon
        let icon = NSTextField(labelWithString: record.type == .voice ? "\u{1F3A4}" : "\u{1F504}")
        icon.font = NSFont.systemFont(ofSize: 18)
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)

        // Text
        let text = NSTextField(wrappingLabelWithString: record.displayText)
        text.font = NSFont.systemFont(ofSize: 13)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isSelectable = false
        if isExpanded {
            text.lineBreakMode = .byWordWrapping
            text.maximumNumberOfLines = 0
        } else {
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = 2
            text.cell?.truncatesLastVisibleLine = true
        }
        cell.addSubview(text)

        // Time
        let time = NSTextField(labelWithString: timeFormatter.string(from: record.timestamp))
        time.font = NSFont.systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        time.translatesAutoresizingMaskIntoConstraints = false
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(time)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 28),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),
            text.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -14),

            time.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            time.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),
            time.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])

        return cell
    }

    // MARK: - Actions

    @objc private func dateFilterChanged() {
        reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Triggered by NSSearchField typing
        reloadData()
    }

    @objc private func rowDoubleClicked() {
        copySelectedToClipboard()
    }

    @objc private func copyClicked() {
        copySelectedToClipboard()
    }

    @objc private func deleteClicked() {
        let selected = tableView?.selectedRowIndexes ?? IndexSet()
        guard !selected.isEmpty else { return }

        let ids = selected.compactMap { idx -> Int64? in
            guard idx < records.count else { return nil }
            return records[idx].id
        }

        for id in ids {
            HistoryStore.shared.delete(id: id)
        }
        reloadData()
    }

    @objc private func clearAllClicked() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all \(records.count) history records."
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

        let texts = selected.compactMap { idx -> String? in
            guard idx < records.count else { return nil }
            return records[idx].copyText
        }

        let combined = texts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        log("History: copied \(texts.count) items to clipboard")

        // Brief visual feedback
        countLabel?.stringValue = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.countLabel?.stringValue = "\(self?.records.count ?? 0) items"
        }
    }

    // MARK: - UI Helpers

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12)
        return btn
    }
}
