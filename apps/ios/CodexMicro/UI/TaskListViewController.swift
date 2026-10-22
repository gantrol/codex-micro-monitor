import UIKit

final class TaskListViewController: UITableViewController, UISearchResultsUpdating {
    private let store: MicroStore
    private let searchController = UISearchController(searchResultsController: nil)
    private var displayedThreads: [MicroThread] = []
    private var nextCursor: String?
    private var isLoadingMore = false
    private var activeQuery = ""

    var onSelectThread: ((String) -> Void)?

    init(store: MicroStore) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "全部任务"
        view.backgroundColor = MicroTheme.backdrop

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索任务标题或目录"
        navigationItem.searchController = searchController
        definesPresentationContext = true

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadFromStart), for: .valueChanged)

        displayedThreads = store.snapshot?.threads ?? []

        store.onThreadsPage = { [weak self] page in
            guard let self else { return }
            self.refreshControl?.endRefreshing()
            if self.isLoadingMore {
                self.isLoadingMore = false
                let existingIDs = Set(self.displayedThreads.map(\.id))
                let appended = page.threads.filter { !existingIDs.contains($0.id) }
                self.displayedThreads.append(contentsOf: appended)
            } else {
                self.displayedThreads = page.threads
            }
            self.nextCursor = page.nextCursor
            self.tableView.reloadData()
        }

        reloadFromStart()
    }

    @objc private func reloadFromStart() {
        isLoadingMore = false
        nextCursor = nil
        store.fetchThreadsList(query: activeQuery.isEmpty ? nil : activeQuery, cursor: nil, limit: 30)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != activeQuery else { return }
        activeQuery = query
        reloadFromStart()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedThreads.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = MicroTheme.paper
        let thread = displayedThreads[indexPath.row]
        var config = cell.defaultContentConfiguration()

        let slotPrefix = thread.slotIndex.map { "#\($0 + 1) " } ?? ""
        config.text = slotPrefix + thread.title
        config.textProperties.font = .preferredFont(forTextStyle: .body)
        config.textProperties.color = MicroTheme.ink

        var metaParts: [String] = [
            thread.workspaceName,
            MicroTheme.statusName(thread.status),
        ]
        if thread.hasDraft { metaParts.append("含草稿") }
        if thread.pendingApprovalCount > 0 { metaParts.append("待审批 \(thread.pendingApprovalCount)") }
        config.secondaryText = metaParts.joined(separator: " · ")
        config.secondaryTextProperties.color = MicroTheme.muted

        let dotImage = UIImage(systemName: "circle.fill")
        config.image = dotImage
        config.imageProperties.tintColor = MicroTheme.status(thread.status)

        cell.contentConfiguration = config
        cell.accessoryType = (thread.id == store.selectedID) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let thread = displayedThreads[indexPath.row]
        store.select(thread.id)
        onSelectThread?(thread.id)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row >= displayedThreads.count - 3,
              let cursor = nextCursor, !cursor.isEmpty,
              !isLoadingMore else {
            return
        }
        isLoadingMore = true
        store.fetchThreadsList(query: activeQuery.isEmpty ? nil : activeQuery, cursor: cursor, limit: 30)
    }
}
