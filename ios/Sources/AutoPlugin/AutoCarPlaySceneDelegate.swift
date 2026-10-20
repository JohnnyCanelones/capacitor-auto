#if canImport(CarPlay)
import CarPlay
import CarplayPlugin
import Foundation
import Network
import Tmtplayer
import UIKit

private final class RadioBaseCarPlayPlaybackCoordinator {
    static let shared = RadioBaseCarPlayPlaybackCoordinator()

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "radiobase.carplay.network")
    private var isOnline = true
    private var timer: Timer?
    private var sessionId = ""
    private var context: [String: Any] = [:]
    private var queue: [[String: Any]] = []
    private var currentIndex = 0
    private var playbackObserver: NSObjectProtocol?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in self?.isOnline = path.status == .satisfied }
        pathMonitor.start(queue: monitorQueue)
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .tmtPlayerPlaybackStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.persist() }
    }

    func play(contentKind: String, book: [String: Any], catalog: [String: Any], selected: Int, localOnly: Bool = false) -> Bool {
        guard
            let audioKey = book["audioKey"] as? String,
            let audio = AutoStore.shared.load(audioKey),
            audio["context"] as? String == catalog["context"] as? String,
            let allTracks = audio["tracks"] as? [[String: Any]],
            selected >= 0,
            selected < allTracks.count
        else { return false }

        var playable: [[String: Any]] = []
        for (offset, track) in allTracks.dropFirst(selected).enumerated() {
            guard let source = source(for: track, localOnly: localOnly) else {
                if offset == 0 { return false }
                if contentKind == "study" || localOnly { continue }
                break
            }
            var item = track
            item["sourceUrl"] = source.url
            item["isLocalFileUrl"] = source.local
            item["resumeSeconds"] = offset == 0 ? number(track["resumeSeconds"]) : 0
            playable.append(item)
        }
        guard !playable.isEmpty else { return false }

        let title = book["title"] as? String ?? ""
        let mediaObjects: [[String: Any]] = playable.map { track in
            let mediaTitle = contentKind == "study"
                ? (track["name"] as? String ?? title)
                : "\(title) \(track["number"] as? String ?? "")"
            return [
                "url": track["sourceUrl"] as? String ?? "",
                "title": mediaTitle,
                "artist": title,
                "image": track["artwork"] as? String ?? "",
                "duration": "0",
                "isStreaming": false,
                "isPlaying": true,
                "isStudy": true,
                "isLocalFileUrl": track["isLocalFileUrl"] as? Bool ?? false,
                "playbackPositionInSeconds": number(track["resumeSeconds"])
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: mediaObjects),
            let items = try? JSONDecoder().decode([TMTPlayerItem].self, from: data)
        else { return false }

        sessionId = UUID().uuidString
        context = [
            "context": catalog["context"] as? String ?? "",
            "contentKind": contentKind,
            "contentType": catalog["contentType"] as? String ?? "",
            "studyLanguage": catalog["studyLanguage"] as? String ?? "",
            "bibleId": catalog["bibleId"] as? String ?? "",
            "audioId": catalog["audioId"] as? String ?? "",
            "bookId": book["id"] as? String ?? "",
            "bookTitle": title,
            "testament": book["testament"] as? String ?? ""
        ]
        queue = playable
        currentIndex = 0
        _ = CarPlayHelper.shared.pauseStreaming()
        TMTPlayer.shared.clearMediaList()
        TMTPlayer.shared.updatePlayerRate(Float(number(catalog["playbackRate"])))
        TMTPlayer.shared.startPlayingMediaList(items) { [weak self] _ in self?.finishedCurrentItem() }
        persist(state: "playing")
        startTimer()
        return true
    }

    private func source(for track: [String: Any], localOnly: Bool) -> (url: String, local: Bool)? {
        if let local = track["localUrl"] as? String, !local.isEmpty {
            let fileURL = URL(string: local)
            let path = fileURL?.isFileURL == true ? fileURL!.path : local.replacingOccurrences(of: "file://", with: "")
            if FileManager.default.fileExists(atPath: path) { return (path, true) }
        }
        if !localOnly, isOnline, let remote = track["url"] as? String, URL(string: remote) != nil { return (remote, false) }
        return nil
    }

    private func finishedCurrentItem() {
        persist(state: "completed")
        currentIndex += 1
        if currentIndex >= queue.count {
            timer?.invalidate()
            timer = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.persist(state: "playing") }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.persist() }
    }

    private func persist(state forcedState: String? = nil) {
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        let info = TMTPlayer.shared.getCurrentMediaItemPlaybackInfo()
        var value = context
        let contentKind = context["contentKind"] as? String ?? "bible"
        value["source"] = contentKind == "study" ? "carplay-study" : "carplay-bible"
        value["sessionId"] = sessionId
        value["state"] = forcedState ?? info["state"] ?? "paused"
        value["positionSeconds"] = number(info["position"])
        value["durationSeconds"] = number(info["durationInSeconds"])
        value["current"] = queue[currentIndex]
        value["currentIndex"] = currentIndex
        value["queue"] = queue
        value["updatedAt"] = Date().timeIntervalSince1970
        let stateKey = contentKind == "study" ? "radiobase.studyPlayback.v1" : "radiobase.biblePlayback.v1"
        AutoStore.shared.save(stateKey, value)
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }
}

@objc(AutoCarPlaySceneDelegate)
public class AutoCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, AutoStoreListener {
    private static let catalogKey = "radiobase.bibleCatalog.v1"
    private static let studyCatalogKey = "radiobase.studyCatalog.v1"
    private var interfaceController: CPInterfaceController?
    private var catalog: [String: Any] = [:]
    private var studyCatalog: [String: Any] = [:]
    private var catalogJSON: Data?
    private var rootTemplate: CPListTemplate?
    private var rootTitle = ""
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "radiobase.carplay.catalog.network")
    private var networkMonitorStarted = false
    private var isOnline = true

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        AutoStore.shared.addListener(self)
        AutoBridge.shared.setConnected(true)
        startNetworkMonitor()
        reloadCatalog()
    }

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        AutoStore.shared.removeListener(self)
        self.interfaceController = nil
        catalogJSON = nil
        rootTemplate = nil
        rootTitle = ""
        AutoBridge.shared.setConnected(false)
    }

    public func onAutoStoreUpdated(_ key: String, value: [String: Any]?, transient: Bool) {
        guard (key == Self.catalogKey || key == Self.studyCatalogKey), !transient else { return }
        DispatchQueue.main.async { [weak self] in self?.reloadCatalog() }
    }

    private func startNetworkMonitor() {
        guard !networkMonitorStarted else { return }
        networkMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let next = path.status == .satisfied
                guard self.isOnline != next else { return }
                self.isOnline = next
                self.reloadCatalog()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func reloadCatalog() {
        guard let interfaceController else { return }
        let stored = AutoStore.shared.load(Self.catalogKey) ?? [:]
        let next = (stored["schemaVersion"] as? Int) == 2 ? stored : [:]
        let storedStudies = AutoStore.shared.load(Self.studyCatalogKey) ?? [:]
        let nextStudies = (storedStudies["schemaVersion"] as? Int) == 1 ? storedStudies : [:]
        let combined: [String: Any] = ["bible": next, "study": nextStudies, "online": isOnline]
        let json = try? JSONSerialization.data(withJSONObject: combined, options: .sortedKeys)
        guard catalogJSON == nil || catalogJSON != json else { return }
        catalog = next
        studyCatalog = nextStudies
        catalogJSON = json
        let stationName = (catalog["stationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (studyCatalog["stationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? label("bible")
        let bible = disclosureRow(label("bible")) { [weak self] in self?.showBible() }
        let study = disclosureRow(label("study")) { [weak self] in self?.showStudies() }
        let downloads = disclosureRow(label("downloads")) { [weak self] in self?.showDownloads() }
        let rootItems = [bible, study, downloads]
        let sections = [CPListSection(items: rootItems)]
        if let rootTemplate, rootTitle == stationName {
            rootTemplate.updateSections(sections)
            return
        }
        let template = CPListTemplate(title: stationName, sections: sections)
        rootTemplate = template
        rootTitle = stationName
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    private func showBible() {
        let books = catalog["books"] as? [[String: Any]] ?? []
        let items = books.isEmpty ? [disabledRow(label("setup"))] : [
            disclosureRow(label("old")) { [weak self] in self?.showBooks("o", offset: 0) },
            disclosureRow(label("new")) { [weak self] in self?.showBooks("n", offset: 0) }
        ]
        push(CPListTemplate(title: label("bible"), sections: [CPListSection(items: items)]))
    }

    private func showStudies() {
        showStudyBooks(offset: 0)
    }

    private func showDownloads() {
        let bibleBooks = downloadedBooks(contentKind: "bible")
        let studyBooks = downloadedBooks(contentKind: "study")
        if bibleBooks.isEmpty && studyBooks.isEmpty {
            push(CPListTemplate(title: label("downloads"), sections: [CPListSection(items: [disabledRow(label("noDownloads"))])]))
        } else if studyBooks.isEmpty {
            showDownloadedBooks(contentKind: "bible", offset: 0)
        } else if bibleBooks.isEmpty {
            showDownloadedBooks(contentKind: "study", offset: 0)
        } else {
            let bible = disclosureRow(label("bibleDownloads")) { [weak self] in
                self?.showDownloadedBooks(contentKind: "bible", offset: 0)
            }
            let study = disclosureRow(label("studyDownloads")) { [weak self] in
                self?.showDownloadedBooks(contentKind: "study", offset: 0)
            }
            push(CPListTemplate(title: label("downloads"), sections: [CPListSection(items: [bible, study])]))
        }
    }

    private func showDownloadedBooks(contentKind: String, offset: Int) {
        let books = downloadedBooks(contentKind: contentKind)
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = books.dropFirst(offset).prefix(pageSize).compactMap { book -> CPListItem? in
            guard let title = book["title"] as? String, !title.isEmpty else { return nil }
            return disclosureRow(title) { [weak self] in
                self?.showDownloadedTracks(book, contentKind: contentKind, offset: 0)
            }
        }
        if offset + pageSize < books.count {
            items.append(disclosureRow(label("more")) { [weak self] in
                self?.showDownloadedBooks(contentKind: contentKind, offset: offset + pageSize)
            })
        }
        if items.isEmpty { items = [disabledRow(label("noDownloads"))] }
        let title = label(contentKind == "study" ? "studyDownloads" : "bibleDownloads")
        push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    private func showDownloadedTracks(_ book: [String: Any], contentKind: String, offset: Int) {
        guard let bookTitle = book["title"] as? String else { return }
        let tracks = contentKind == "study" ? studyTracksForBook(book) : tracksForBook(book)
        let downloaded = Array(tracks.enumerated()).filter { localPath($0.element) != nil }
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = downloaded.dropFirst(offset).prefix(pageSize).map { entry -> CPListItem in
            let track = entry.element
            let title = contentKind == "study"
                ? (track["name"] as? String ?? bookTitle)
                : (track["number"] as? String ?? bookTitle)
            let detail = contentKind == "study"
                ? (track["passage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                : nil
            let item = CPListItem(text: title, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.playDownloaded(book, contentKind: contentKind, selected: entry.offset)
                completion()
            }
            return item
        }
        if offset + pageSize < downloaded.count {
            items.append(disclosureRow(label("more")) { [weak self] in
                self?.showDownloadedTracks(book, contentKind: contentKind, offset: offset + pageSize)
            })
        }
        if items.isEmpty { items = [disabledRow(label("noDownloads"))] }
        push(CPListTemplate(title: bookTitle, sections: [CPListSection(items: items)]))
    }

    private func playDownloaded(_ book: [String: Any], contentKind: String, selected: Int) {
        let selectedCatalog = contentKind == "study" ? studyCatalog : catalog
        guard RadioBaseCarPlayPlaybackCoordinator.shared.play(
            contentKind: contentKind,
            book: book,
            catalog: selectedCatalog,
            selected: selected,
            localOnly: true
        ) else {
            showAlert(label("offlineAudio"))
            return
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func downloadedBooks(contentKind: String) -> [[String: Any]] {
        let selectedCatalog = contentKind == "study" ? studyCatalog : catalog
        let books = (selectedCatalog["books"] as? [[String: Any]] ?? [])
            .filter { book in
                let tracks = contentKind == "study" ? studyTracksForBook(book) : tracksForBook(book)
                return tracks.contains { localPath($0) != nil }
            }
        return contentKind == "study"
            ? books.sorted { number($0["studyOrder"]) < number($1["studyOrder"]) }
            : books
    }

    private func showStudyBooks(offset: Int) {
        let books = (studyCatalog["books"] as? [[String: Any]] ?? [])
            .sorted { number($0["studyOrder"]) < number($1["studyOrder"]) }
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = books.dropFirst(offset).prefix(pageSize).compactMap { book -> CPListItem? in
            guard let bookTitle = book["title"] as? String, !bookTitle.isEmpty else { return nil }
            return disclosureRow(bookTitle) { [weak self] in self?.showStudyTracks(book, offset: 0) }
        }
        if offset + pageSize < books.count {
            items.append(disclosureRow(studyLabel("more")) { [weak self] in
                self?.showStudyBooks(offset: offset + pageSize)
            })
        }
        if items.isEmpty { items = [disabledRow(studyLabel("noStudies"))] }
        push(CPListTemplate(title: studyLabel("study"), sections: [CPListSection(items: items)]))
    }

    private func showStudyTracks(_ book: [String: Any], offset: Int) {
        guard let title = book["title"] as? String else { return }
        let tracks = studyTracksForBook(book)
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = tracks.dropFirst(offset).prefix(pageSize).enumerated().compactMap { _, track -> CPListItem? in
            guard let name = track["name"] as? String, !name.isEmpty else { return nil }
            let trackIndex = tracks.firstIndex { ($0["id"] as? String) == (track["id"] as? String) }
            let playable = hasSource(track)
            let detail = playable ? (track["passage"] as? String).flatMap { $0.isEmpty ? nil : $0 } : studyLabel("noAudio")
            let item = CPListItem(text: name, detailText: detail)
            item.isEnabled = playable
            if playable, let trackIndex {
                item.handler = { [weak self] _, completion in
                    self?.playStudy(book, selected: trackIndex)
                    completion()
                }
            }
            return item
        }
        if offset + pageSize < tracks.count {
            items.append(disclosureRow(studyLabel("more")) { [weak self] in
                self?.showStudyTracks(book, offset: offset + pageSize)
            })
        }
        if items.isEmpty { items = [disabledRow(studyLabel("noStudies"))] }
        push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    private func playStudy(_ book: [String: Any], selected: Int) {
        guard RadioBaseCarPlayPlaybackCoordinator.shared.play(
            contentKind: "study",
            book: book,
            catalog: studyCatalog,
            selected: selected
        ) else {
            showAlert(studyLabel("offlineAudio"))
            return
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func showBooks(_ testament: String, offset: Int) {
        let books = (catalog["books"] as? [[String: Any]] ?? []).filter { ($0["testament"] as? String) == testament }
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = books.dropFirst(offset).prefix(pageSize).compactMap { book -> CPListItem? in
            guard let title = book["title"] as? String, !title.isEmpty else { return nil }
            return disclosureRow(title) { [weak self] in self?.showChapters(book, offset: 0) }
        }
        if offset + pageSize < books.count {
            items.append(disclosureRow(label("more")) { [weak self] in self?.showBooks(testament, offset: offset + pageSize) })
        }
        if items.isEmpty { items = [disabledRow(label("empty"))] }
        push(CPListTemplate(title: label(testament == "o" ? "old" : "new"), sections: [CPListSection(items: items)]))
    }

    private func showChapters(_ book: [String: Any], offset: Int) {
        guard let title = book["title"] as? String else { return }
        let chapters = book["chapters"] as? [[String: Any]] ?? []
        let tracks = tracksForBook(book)
        let pageSize = max(1, min(100, CPListTemplate.maximumItemCount - 1))
        var items = chapters.dropFirst(offset).prefix(pageSize).enumerated().compactMap { relative, chapter -> CPListItem? in
            guard let number = chapter["number"] as? String, !number.isEmpty else { return nil }
            let trackIndex = tracks.firstIndex { ($0["number"] as? String) == number }
            let hasAudio = trackIndex.map { hasSource(tracks[$0]) } ?? false
            let item = CPListItem(text: number, detailText: hasAudio ? nil : label("noAudio"))
            item.isEnabled = hasAudio
            if hasAudio {
                item.handler = { [weak self] _, completion in
                    self?.playChapter(book, selected: trackIndex!)
                    completion()
                }
            }
            return item
        }
        if offset + pageSize < chapters.count {
            items.append(disclosureRow(label("moreChapters")) { [weak self] in self?.showChapters(book, offset: offset + pageSize) })
        }
        if items.isEmpty { items = [disabledRow(label("emptyChapters"))] }
        push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    private func playChapter(_ book: [String: Any], selected: Int) {
        guard RadioBaseCarPlayPlaybackCoordinator.shared.play(contentKind: "bible", book: book, catalog: catalog, selected: selected) else {
            showAlert(label("offlineAudio"))
            return
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func tracksForBook(_ book: [String: Any]) -> [[String: Any]] {
        guard
            let key = book["audioKey"] as? String,
            let state = AutoStore.shared.load(key),
            state["context"] as? String == catalog["context"] as? String
        else { return [] }
        return state["tracks"] as? [[String: Any]] ?? []
    }

    private func studyTracksForBook(_ book: [String: Any]) -> [[String: Any]] {
        guard
            let key = book["audioKey"] as? String,
            let state = AutoStore.shared.load(key),
            state["context"] as? String == studyCatalog["context"] as? String
        else { return [] }
        return (state["tracks"] as? [[String: Any]] ?? [])
            .sorted { number($0["teachingOrder"]) < number($1["teachingOrder"]) }
    }

    private func hasSource(_ track: [String: Any]) -> Bool {
        localPath(track) != nil || !((track["url"] as? String) ?? "").isEmpty
    }

    private func localPath(_ track: [String: Any]) -> String? {
        guard let local = track["localUrl"] as? String, !local.isEmpty else { return nil }
        let fileURL = URL(string: local)
        let path = fileURL?.isFileURL == true
            ? fileURL!.path
            : local.replacingOccurrences(of: "file://", with: "")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func showAlert(_ title: String) {
        let action = CPAlertAction(title: label("close"), style: .cancel) { _ in }
        interfaceController?.presentTemplate(CPAlertTemplate(titleVariants: [title], actions: [action]), animated: true, completion: nil)
    }

    private func push(_ template: CPTemplate) {
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func disclosureRow(_ title: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.accessoryType = .disclosureIndicator
        item.handler = { _, completion in action(); completion() }
        return item
    }

    private func disabledRow(_ title: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.isEnabled = false
        return item
    }

    private func label(_ key: String) -> String {
        if let labels = catalog["labels"] as? [String: String], let value = labels[key], !value.isEmpty { return value }
        if let labels = studyCatalog["labels"] as? [String: String], let value = labels[key], !value.isEmpty { return value }
        let spanish = Locale.preferredLanguages.first?.hasPrefix("es") == true
        let defaults = spanish
            ? ["bible": "Biblia", "old": "Antiguo Testamento", "new": "Nuevo Testamento", "study": "Estudio",
               "setup": "Biblia no disponible", "empty": "Biblia no disponible", "noStudies": "No hay estudios disponibles",
               "more": "Ver más", "emptyChapters": "No hay capítulos", "moreChapters": "Ver más",
               "noAudio": "No hay audio disponible", "offlineAudio": "No se puede reproducir sin conexión", "close": "Cerrar",
               "downloads": "Administrar Descargas", "bibleDownloads": "Descargas Bíblicas",
               "studyDownloads": "Descargas de Estudio", "noDownloads": "No Hay Datos Descargados"]
            : ["bible": "Bible", "old": "Old Testament", "new": "New Testament", "study": "Study",
               "setup": "Bible not available", "empty": "Bible not available", "noStudies": "No studies available",
               "more": "See More", "emptyChapters": "No chapters available", "moreChapters": "See More",
               "noAudio": "No audio available", "offlineAudio": "Unable to play offline", "close": "Close",
               "downloads": "Manage Downloads", "bibleDownloads": "Bible Downloads",
               "studyDownloads": "Study Downloads", "noDownloads": "No Downloaded Data"]
        return defaults[key] ?? key
    }

    private func studyLabel(_ key: String) -> String {
        if let labels = studyCatalog["labels"] as? [String: String], let value = labels[key], !value.isEmpty { return value }
        return label(key)
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }
}
#endif
