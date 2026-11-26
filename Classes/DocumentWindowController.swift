//
//  DocumentWindowController.swift
//  Subler
//
//  Created by Damiano Galassi on 03/02/2018.
//

import Cocoa
import MP42Foundation
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSWindowDelegate, TracksViewControllerDelegate, MetadataSearchViewControllerDelegate, ChapterSearchControllerDelegate, FileImportControllerDelegate, ProgressViewControllerDelegate, NSDraggingDestination, NSUserInterfaceValidations {

    private var doc: Document {
        return document as! Document
    }

    private var mp4: MP42File {
        return doc.mp4
    }

    override var windowNibName: NSNib.Name? {
        return "DocumentWindowController"
    }

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let toolbarDelegate = DocumentToolbarDelegate()

    override func windowDidLoad() {
        super.windowDidLoad()

        guard let window = window else {
            fatalError("`window` is expected to be non nil by this time.")
        }

        if #available(macOS 11, *) {
            window.toolbarStyle = .expanded
        }

        toolbarDelegate.target = self

        let toolbar = NSToolbar(identifier: "SublerDocumentToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 26, *) {
            toolbar.displayMode = .iconOnly
        } else {
            toolbar.displayMode = .iconAndLabel
        }
        self.window?.toolbar = toolbar

        window.contentViewController = splitViewController
        window.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])

        if Prefs.rememberDocumentWindowSize {
            window.setFrameAutosaveName("documentSave")
            window.setFrameUsingName("documentSave")

            splitViewController.splitView.autosaveName = DocumentWindowController.splitViewResorationAutosaveName
            splitViewController.splitView.identifier = DocumentWindowController.splitViewResorationIdentifier
        }
        else {
            window.setContentSize(NSSize(width: 692, height: 600))
            splitViewController.splitView.setPosition(240, ofDividerAt: 0)
        }

        didSelect(tracks: [])

        let update: (Notification) -> Void = { [weak self] notification in
            guard let s = self else { return }
            s.reloadDataAfterAnUndo()
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSUndoManagerDidUndoChange,
                                               object: doc.undoManager,
                                               queue: OperationQueue.main,
                                               using: update)

        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSUndoManagerDidRedoChange,
                                               object: doc.undoManager,
                                               queue: OperationQueue.main,
                                               using: update)
    }

    private static let splitViewResorationIdentifier = NSUserInterfaceItemIdentifier(rawValue: "splitViewSave")
    private static let splitViewResorationAutosaveName = "splitViewSave"

    private lazy var splitViewController: NSSplitViewController = {
        // Create a split view controller to contain split view items.
        let splitViewController = NSSplitViewController()
        splitViewController.view.wantsLayer = true
        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = NSSplitView.DividerStyle.thick

        let tracksSplitViewItem = NSSplitViewItem(viewController: tracksViewController)
        tracksSplitViewItem.minimumThickness = 100

        splitViewController.addSplitViewItem(tracksSplitViewItem)

        let detailsSplitViewItem = NSSplitViewItem(viewController: DetailsViewController())
        detailsSplitViewItem.canCollapse = true
        detailsSplitViewItem.minimumThickness = 320

        splitViewController.addSplitViewItem(detailsSplitViewItem)

        return splitViewController
    }()

    private lazy var tracksViewController: TracksViewController = {
        let tracksViewController = TracksViewController(document: doc, delegate: self)
        return tracksViewController
    }()

    private var metadataViewController: MovieViewController?
    private var videoViewController: VideoViewController?
    private var soundViewController: SoundViewController?
    private var chapterViewController: ChapterViewController?
    private var multiViewController: MultiSelectViewController?
    private var emptyViewController: EmptyViewController?

    private var selectedTabIndexesDict: [String:Int] = [:]

    private func saveTabIndex(_ propertyView: PropertyView?) {
        if let propertyView {
            selectedTabIndexesDict[String(describing: type(of: propertyView))] =  propertyView.selectedViewIndex()
        }
    }

    private func selectTabViewItem(for propertyView: PropertyView) {
        let key = String(describing: type(of: propertyView))
        if let tabIndex = selectedTabIndexesDict[key] {
            propertyView.selectTabViewItem(at: tabIndex)
            selectedTabIndexesDict.removeValue(forKey: key)
        }
    }

    private func clearDetailsViewControllers() {
        saveTabIndexes()
        metadataViewController = nil
        videoViewController = nil
        soundViewController = nil
        chapterViewController = nil
        multiViewController = nil
    }

    private func saveTabIndexes() {
        saveTabIndex(metadataViewController)
        saveTabIndex(videoViewController)
        saveTabIndex(soundViewController)
    }

    private func detailsViewController(_ tracks: [MP42Track]) -> PropertyView {
        if tracks.count > 1 {
            let controller = MultiSelectViewController(numberOfTracks: UInt(tracks.count))
            return controller
        } else {
            switch tracks.first {

            case let track as MP42VideoTrack:
                if let videoViewController = videoViewController {
                    videoViewController.track = track
                } else {
                    videoViewController = VideoViewController(mp4: mp4, track: track)
                }
                return videoViewController!

            case let track as MP42AudioTrack:
                if let soundViewController = soundViewController {
                    soundViewController.track = track
                } else {
                    soundViewController = SoundViewController(mp4: mp4, track: track)
                }
                return soundViewController!

            case let track as MP42ChapterTrack:
                if let chapterViewController = chapterViewController {
                    chapterViewController.track = track
                } else {
                    chapterViewController = ChapterViewController(track: track)
                }
                return chapterViewController!

            case let track where track != nil:
                if emptyViewController == nil {
                    emptyViewController = EmptyViewController()
                }
                return emptyViewController!

            default:
                if let metadataViewController = metadataViewController {
                    metadataViewController.metadata = mp4.metadata
                }
                else {
                    metadataViewController = MovieViewController(mp4: mp4, metadata: mp4.metadata)
                }
                return metadataViewController!
            }
        }
    }

    func reloadData() {
        clearDetailsViewControllers()
        tracksViewController.mp4 = doc.mp4
    }

    func reloadDataAfterAnUndo() {
        let firstResponder = self.window?.firstResponder;
        saveTabIndexes()
        tracksViewController.reloadData()
        if let firstResponder = firstResponder as? NSView, firstResponder.window != nil {
            self.window?.makeFirstResponder(firstResponder)
        }
    }

    // MARK: Tracks controller delegate

    func didSelect(tracks: [MP42Track]) {
        let detailsItem = splitViewController.splitViewItems[1]
        if let detailsViewController = detailsItem.viewController.children.first {
            detailsViewController.view.removeFromSuperviewWithoutNeedingDisplay()
            detailsItem.viewController.removeChild(at: 0)
        }

        let trackViewController = detailsViewController(tracks)
        detailsItem.viewController.addChild(trackViewController)
        trackViewController.view.frame = detailsItem.viewController.view.bounds
        trackViewController.view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        detailsItem.viewController.view.addSubview(trackViewController.view)

        // Tags-only mode: tracks are displayed but cannot be modified, except
        // for the fields MP42MkvTagWriter writes back (see allowsTrackEditing)
        // and the chapters tab (ChapterViewController edits ride the remuxer's
        // replacementChapters). Set after the view is loaded so it wins over
        // controls that the view controllers enable during their own updates.
        trackViewController.isMatroskaDocument = doc.isMatroska
        if doc.isMatroska, !(trackViewController is MovieViewController),
           !(trackViewController is ChapterViewController) {
            trackViewController.allowsTrackEditing = true
            trackViewController.isReadOnly = true
        } else {
            trackViewController.allowsTrackEditing = false
            trackViewController.isReadOnly = false
        }

        selectTabViewItem(for: trackViewController)
    }

    func delete(tracks: [MP42Track]) {
        // On MKV docs the save path stream-copy-remuxes removed real tracks'
        // blocks away (MP42MkvRemuxer); a removed chapter pseudo-track makes
        // the model report "no chapters", which deletes the Chapters element.
        if tracks.isEmpty == false {
            mp4.removeTracks(tracks)

            if doc.isMatroska == false {
                // Both heuristics reorder the track model, which would break
                // the TrackEntry/order pairing the MKV writers depend on.
                if Prefs.organizeAlternateGroups { mp4.organizeAlternateGroups() }
                if Prefs.inferMediaCharacteristics { mp4.inferMediaCharacteristics() }
            }

            tracksViewController.reloadData()
        }
    }

    // MARK: Validation

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {

        case #selector(selectMetadataFile(_:)),
             #selector(searchMetadata(_:)),
             #selector(sendToQueue(_:)),
             #selector(insertChapter(_:)),
             #selector(addChaptersEvery(_:)):
            return true

        // Matroska documents may import subtitle text files (written as
        // S_TEXT/UTF8 by the stream-copy remuxer on save).
        case #selector(selectFile(_:)):
            return true

        // Track bulk modifications (and the chapter-DB search, whose apply
        // path lacks the tags-only bookkeeping): unavailable in Matroska
        // tags-only mode. The Insert-a-chapter actions are NOT on this list —
        // chapter changes ride the stream-copy remuxer, so they work on MKV.
        case #selector(searchChapters(_:)),
             #selector(iTunesFriendlyTrackGroups(_:)),
             #selector(clearTrackNames(_:)),
             #selector(prettifyAudioTrackNames(_:)),
             #selector(fixAudioFallbacks(_:)):
            return !doc.isMatroska

        case #selector(sendToExternalApp(_:)) where mp4.hasFileRepresentation && doc.isDocumentEdited == false:
            return true

        case #selector(showTrackOffsetSheet(_:)) where doc.isMatroska == false && tracksViewController.selectedTracks.isEmpty == false:
            return true

        case #selector(export(_:)) where tracksViewController.selectedTracks.isEmpty == false:
            if let track = tracksViewController.selectedTracks.first, track.isMuxed, track.canExport {
                return true
            } else {
                return false
            }

        case #selector(DocumentWindowController.deleteTrack(_:)):
            // MKV documents allow deleting real tracks (stream-copy remux on
            // save) and the chapter pseudo-track (the Chapters element is
            // removed on save), so any non-empty selection is deletable.
            return tracksViewController.selectedTracks.isEmpty == false && NSApp.isActive

        default:
            return false
        }
    }

    // MARK: Save status

    private var progressController: ProgressViewController?

    func startProgressReporting() {
        let progressController = ProgressViewController()
        progressController.delegate = self
        contentViewController?.presentAsSheet(progressController)
        self.progressController = progressController
        mp4.progressHandler = { [weak progressController] progress in
            DispatchQueue.main.async {
                guard let progressController = progressController else { return }
                progressController.progress = progress
            }
        }
    }

    func setProgress(title: String) {
        if let progressController = self.progressController {
            progressController.progressTitle = title
        }
    }

    func endProgressReporting() {
        mp4.progressHandler = nil
        if let progressController = self.progressController {
            contentViewController?.dismiss(progressController)
            self.progressController = nil
        }
    }

    func cancelSave() {
        doc.cancelSave()
    }

    // MARK: Actions

    @IBAction func sendToQueue(_ sender: Any) {
        doc.sendToQueue(self)
    }

    @IBAction func sendToExternalApp(_ sender: Any) {
        if let fileURL = doc.fileURL {
            _ = sendToFileExternalApp(fileURL: fileURL)
        }
    }

    @IBAction func deleteTrack(_ sender: Any) {
        delete(tracks: tracksViewController.selectedTracks)
    }

    // Single-chapter insert that also bootstraps the chapter track, so it
    // works on documents without any chapters yet (both containers: on MKV
    // the new rows ride the remuxer on save, like the Chapters tab's edits).
    @IBAction func insertChapter(_ sender: Any) {
        let track: MP42ChapterTrack
        if let existing = mp4.chapters {
            track = existing
        } else {
            track = MP42ChapterTrack()
            mp4.addTrack(track) // addTrack: replaces any previous chapter track
            if doc.isMatroska {
                // addTrack: zeroes trackId; keep the table numbering dense.
                track.trackId = (mp4.tracks.map { $0.trackId }.max() ?? 0) + 1
            }
        }

        // A brand-new track gets its first chapter at 0; inserting into an
        // existing track places the chapter 1s after the latest start, so it
        // never ties with a stored chapter (ties get clamped +1ms on write,
        // which would silently shift the user's own chapter times). The user
        // retimes/renames the row either way.
        var newTimestamp: UInt64 = 0
        if let last = track.chapters.max(by: { $0.timestamp < $1.timestamp }) {
            newTimestamp = last.timestamp + 1000
            if track.duration > last.timestamp + 1, newTimestamp >= track.duration {
                newTimestamp = track.duration - 1
            }
        }
        let index = track.addChapter("Chapter", timestamp: newTimestamp)

        if doc.isMatroska {
            // The tags-only model has no muxing step to mark the document.
            doc.updateChangeCount(.changeDone)
        }

        tracksViewController.reloadData()
        tracksViewController.selectTracks([track])
        chapterViewController?.selectChapter(at: Int(index))
    }

    @IBAction func addChaptersEvery(_ sender: NSMenuItem) {
        // Creates the chapter track when the document has none (same
        // bookkeeping as insertChapter: addTrack: zeroes trackId and the
        // tags-only model has no muxing step to mark the document dirty).
        let existing = mp4.chapters
        let track: MP42ChapterTrack = existing ?? MP42ChapterTrack()
        if existing == nil {
            mp4.addTrack(track) // addTrack: replaces any previous chapter track
            if doc.isMatroska {
                track.trackId = (mp4.tracks.map { $0.trackId }.max() ?? 0) + 1
            }
        }
        let minutes = sender.tag * 60 * 1000

        if minutes > 0 {
            for (index, timestamp) in stride(from: 0, to: mp4.duration, by: minutes).enumerated() {
                track.addChapter("Chapter \(index + 1)", timestamp: UInt64(timestamp))
            }
        }
        else {
            track.addChapter("Chapter 1", timestamp: 0)
        }

        if doc.isMatroska {
            doc.updateChangeCount(.changeDone)
        }

        tracksViewController.reloadData()
        tracksViewController.selectTracks([track])
    }

    @IBAction func iTunesFriendlyTrackGroups(_ sender: Any) {
        mp4.organizeAlternateGroups()
        mp4.inferTracksLanguages()
        mp4.inferMediaCharacteristics()

        tracksViewController.reloadData()
    }

    @IBAction func clearTrackNames(_ sender: Any) {
        for track in mp4.tracks {
            track.name = ""
        }

        tracksViewController.reloadData()
    }

    @IBAction func prettifyAudioTrackNames(_ sender: Any) {

        for track in mp4.tracks.compactMap({ $0 as? MP42AudioTrack }) {
            track.name = track.prettyTrackName
        }

        tracksViewController.reloadData()
    }

    @IBAction func fixAudioFallbacks(_ sender: Any) {
        mp4.setAutoFallback()
        tracksViewController.reloadData()
    }

    @IBAction func showTrackOffsetSheet(_ sender: Any) {
        guard let track = tracksViewController.selectedTracks.first else { return }
        let controller = OffsetViewController(doc: doc, track: track)
        self.window?.contentViewController?.presentAsSheet(controller)
    }

    @IBAction func export(_ sender: Any) {
        guard let fileName = doc.fileURL?.deletingPathExtension().lastPathComponent,
            let track = tracksViewController.selectedTracks.first,
            let windowForSheet = doc.windowForSheet
        else { return }

        let ext = (track as? MP42SubtitleTrack) != nil ? "srt" : "txt"

        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true
        panel.nameFieldStringValue = "\(fileName).\(track.trackId).\(track.language).\(ext)"

        panel.beginSheetModal(for: windowForSheet) { (response) in
            if response == NSApplication.ModalResponse.OK, let url = panel.url {
                do {
                    try track.export(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: "Export alert panel -> button"))
                    alert.messageText = NSLocalizedString("File Could Not Be Saved", comment: "Export alert panel -> title")
                    alert.informativeText = NSLocalizedString("There was a problem creating the file ", comment: "Export alert panel -> message") + url.lastPathComponent + "."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    // MARK: Metadata

    @IBAction func searchMetadata(_ sender: Any?) {
        let terms = mp4.extractSearchTerms(fallbackURL : doc.fileURL)
        let controller = MetadataSearchViewController(delegate: self, searchTerms: terms)
        self.contentViewController?.presentAsSheet(controller)
    }

    func didSelect(metadata: MetadataResult) {
        let map = metadata.mediaKind == .movie ? MetadataPrefs.movieResultMap : MetadataPrefs.tvShowResultMap
        let keepEmptyKeys = MetadataPrefs.keepEmptyAnnotations
        let overwriteExisting = MetadataPrefs.overwriteExistingAnnotations

        let result = metadata.mappedMetadata(to: map, keepEmptyKeys: keepEmptyKeys)
        mp4.metadata.merge(result, overwrite: overwriteExisting)

        if let hdType = mp4.hdType {
            for item in mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyHDVideo) {
                mp4.metadata.removeItem(item)
            }
            mp4.metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyHDVideo, value: NSNumber(value: hdType.rawValue),
                                                  dataType: .integer, extendedLanguageTag: nil))
        }
        metadataViewController?.metadata = mp4.metadata
        tracksViewController.selectTracks([])
    }

    @IBAction func searchChapters(_ sender: Any?) {
          let name = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue
          let url = mp4.firstSourceURL ?? doc.fileURL
          let title = (name?.isEmpty == false ? name : url?.lastPathComponent) ?? ""
          let duration = UInt64(mp4.duration)

          let controller = ChapterSearchController(delegate: self, title: title, duration: duration)
          contentViewController?.presentAsSheet(controller)
    }

    func didSelect(chapters: [MP42TextSample]) {
        let chapterTrack = MP42ChapterTrack()
        for chapter in chapters {
            chapterTrack.addChapter(chapter)
        }

        mp4.addTrack(chapterTrack)
        tracksViewController.reloadData()
        tracksViewController.selectTracks([chapterTrack])
    }

    // MARK: File import

    private func addChapters(fileURL: URL) {
        let track = MP42ChapterTrack(fromFile: fileURL)
        mp4.addTrack(track) // replaces any previous chapter track
        if doc.isMatroska {
            // addTrack: zeroes trackId; keep the table numbering dense, and
            // flag the document dirty (the tags-only model has no muxing to
            // mark it, same as importSubtitleTracksForMatroska).
            track.trackId = (mp4.tracks.map { $0.trackId }.max() ?? 0) + 1
            doc.updateChangeCount(.changeDone)
        }
        tracksViewController.reloadData()
        tracksViewController.selectTracks([track])
    }

    private func updateChapters(fileURL: URL) {
        do {
            try mp4.chapters?.update(fromCSVFile: fileURL)
            if let track = mp4.chapters {
                chapterViewController?.track = track
                tracksViewController.selectTracks([track])
                if doc.isMatroska { doc.updateChangeCount(.changeDone) }
            }
        }
        catch {
            if let windowForSheet = doc.windowForSheet {
                presentError(error, modalFor: windowForSheet, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                presentError(error)
            }
        }
    }

    private func addMetadata(fileURL: URL) {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "xml" || ext == "nfo", let metadata = MP42Metadata(url: fileURL) {
            mp4.metadata.merge(metadata, overwrite: true)
            metadataViewController?.metadata = mp4.metadata
            tracksViewController.selectTracks([])
        } else if let file = try? MP42File(url: fileURL) {
            mp4.metadata.merge(file.metadata, overwrite: true)
            metadataViewController?.metadata = mp4.metadata
            tracksViewController.selectTracks([])
        }
    }

    @IBAction func selectMetadataFile(_ sender: Any) {
        guard let windowForSheet = doc.windowForSheet else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if #available(macOS 12, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .mpeg4Audio,
                                         .appleProtectedMPEG4Video,
                                         .xml, UTType(filenameExtension: "nfo")!]
        } else {
            panel.allowedFileTypes = ["mp4", "m4v", "m4a", "xml", "nfo"]
        }

        panel.beginSheetModal(for: windowForSheet) { (response) in
            if response == NSApplication.ModalResponse.OK, let url = panel.url {
                self.addMetadata(fileURL: url)
            }
        }
    }

    @IBAction func selectFile(_ sender: Any) {
        guard let windowForSheet = doc.windowForSheet else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if doc.isMatroska {
            // A Matroska document can gain subtitle text tracks (the
            // stream-copy remuxer writes them as S_TEXT/UTF8) and chapters
            // (.txt creates/replaces the chapter track, .csv updates an
            // existing one — same dispatch the MP4 branch uses below).
            let chapterExtensions = ["txt", "csv"]
            if #available(macOS 11, *) {
                panel.allowedContentTypes = (DocumentWindowController.matroskaSubtitleExtensions + chapterExtensions).compactMap {
                    UTType(filenameExtension: $0)
                }
            } else {
                panel.allowedFileTypes = DocumentWindowController.matroskaSubtitleExtensions + chapterExtensions
            }
            panel.beginSheetModal(for: windowForSheet) { (response) in
                guard response == NSApplication.ModalResponse.OK else { return }
                var subtitleURLs: [URL] = []
                for url in panel.urls {
                    switch url.pathExtension.lowercased() {
                    case "txt": self.addChapters(fileURL: url)
                    case "csv": self.updateChapters(fileURL: url)
                    default: subtitleURLs.append(url)
                    }
                }
                if subtitleURLs.isEmpty == false {
                    self.showImportSheet(fileURLs: subtitleURLs)
                }
            }
            return
        }

        if #available(macOS 11, *) {
            panel.allowedContentTypes = MP42FileImporter.supportedContentTypes() + [.text, .commaSeparatedText]
        } else {
            panel.allowedFileTypes = MP42FileImporter.supportedFileFormats() + ["txt", "csv"]
        }

        panel.beginSheetModal(for: windowForSheet) { (response) in
            if response == NSApplication.ModalResponse.OK {
                let ext = panel.url?.pathExtension.lowercased()
                if ext == "txt", let url = panel.url {
                    self.addChapters(fileURL: url)
                }
                else if ext == "csv", let url = panel.url {
                    self.updateChapters(fileURL: url)
                }
                else {
                    self.showImportSheet(fileURLs: panel.urls)
                }
            }
        }
    }

    /// Subtitle text files a Matroska document can gain — must stay in sync
    /// with the extension gate in MP42MkvRemuxer's added-track validation.
    static let matroskaSubtitleExtensions = ["srt", "ssa", "ass"]

    func showImportSheet(fileURLs: [URL]) {
        if doc.isMatroska {
            importSubtitleTracksForMatroska(fileURLs: fileURLs)
            return
        }

        do {
            let controller = try FileImportController(fileURLs: fileURLs, delegate: self)

            if controller.onlyContainsSubtitles {
                controller.addTracks(self)
                tracksViewController.reloadData()
            } else {
                contentViewController?.presentAsSheet(controller)
            }
        }
        catch {
            if let windowForSheet = doc.windowForSheet {
                presentError(error, modalFor: windowForSheet, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                presentError(error)
            }
        }
    }

    // A Matroska document gains subtitle tracks by re-parsing the source text
    // file at save time (MP42MkvRemuxer writes S_TEXT/UTF8 BlockGroups), so
    // the model only needs the track object with its URL — no FileImportController
    // sheet, and crucially none of didSelect's organizeAlternateGroups/
    // inferMediaCharacteristics churn, which would shift model indices and
    // break the remuxer's TrackEntry↔sourceTracks identity pairing.
    func importSubtitleTracksForMatroska(fileURLs: [URL]) {
        let allowed = DocumentWindowController.matroskaSubtitleExtensions
        let subtitleURLs = fileURLs.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard subtitleURLs.isEmpty == false else { return }

        var addedTracks: [MP42Track] = []
        var nextDisplayId: MP42TrackId = (mp4.tracks.map { $0.trackId }.max() ?? 0) + 1
        for url in subtitleURLs {
            do {
                let importer = try MP42FileImporter(url: url)
                for track in importer.tracks {
                    guard track.isMember(of: MP42ChapterTrack.self) == false else { continue }
                    // Same addTrack: invariant the tags-only read establishes
                    // (see Document.readMatroska) — codecs MP4 cannot carry
                    // as-is must carry conversion settings.
                    if trackNeedConversion(track.format) {
                        (track as? MP42SubtitleTrack)?.conversionSettings = MP42ConversionSettings.subtitlesConversion()
                    }
                    mp4.addTrack(track)
                    // addTrack: zeroes trackId; keep the table numbering dense.
                    track.trackId = nextDisplayId
                    nextDisplayId += 1
                    addedTracks.append(track)
                }
            }
            catch {
                if let windowForSheet = doc.windowForSheet {
                    presentError(error, modalFor: windowForSheet, delegate: nil, didPresent: nil, contextInfo: nil)
                } else {
                    presentError(error)
                }
            }
        }

        guard addedTracks.isEmpty == false else { return }
        doc.updateChangeCount(.changeDone)
        tracksViewController.reloadData()
        tracksViewController.selectTracks(addedTracks)
    }

    @objc func importFilesDirectly(_ fileURLs: [URL]) {
        do {
            let controller = try FileImportController(fileURLs: fileURLs, delegate: self)

            // Call addTracks directly - the Settings initialization logic runs when the controller is created
            controller.addTracks(self)
            tracksViewController.reloadData()
        } catch {
            if let windowForSheet = doc.windowForSheet {
                presentError(error, modalFor: windowForSheet, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                presentError(error)
            }
        }
    }

    func didSelect(tracks: [MP42Track], metadata: MP42Metadata?) {
        for track in tracks {
            mp4.addTrack(track)
        }

        // Reordering must never touch a Matroska document: the remuxer pairs
        // TrackEntry elements against mkvSourceTracks by identity, and a
        // reordered model would mispair them (same rule as delete(tracks:)).
        if tracks.isEmpty == false, doc.isMatroska == false {
            if Prefs.organizeAlternateGroups {
                mp4.organizeAlternateGroups()
                if Prefs.inferMediaCharacteristics {
                    mp4.inferTracksLanguages()
                    mp4.inferMediaCharacteristics()
                }
            }
        }

        if let metadata, metadata.items.isEmpty == false {
            mp4.metadata.merge(metadata, overwrite: true)
        }

        tracksViewController.reloadData()

        if let metadata, metadata.items.isEmpty == false {
            tracksViewController.selectTracks([])
        } else if tracks.isEmpty == false {
            tracksViewController.selectTracks(tracks)
        }
    }

    // MARK: Drag & drop

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
            types.contains(NSPasteboard.PasteboardType.fileURL) &&
                sender.draggingSourceOperationMask.contains(.copy)
        else { return [] }

        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let types = pasteboard.types,
            types.contains(NSPasteboard.PasteboardType.fileURL),
            let items = pasteboard.readObjects(forClasses: [NSURL.classForCoder()], options: [:]) as? [URL]
            else { return false }

        // Metadata drops are fine in tags-only mode. Chapters ride the
        // remuxer on Matroska documents, so txt/csv drops route there too;
        // everything else that would add a track goes through the import
        // panel (which routes Matroska docs to the subtitle-only path).
        if doc.isMatroska {
            if let url = items.first(where: { $0.pathExtension.lowercased() == "txt" }) {
                addChapters(fileURL: url)
            }
            if let url = items.first(where: { $0.pathExtension.lowercased() == "csv" }) {
                updateChapters(fileURL: url)
            }
        } else if let url = items.first(where: { $0.pathExtension.lowercased() == "txt" }) {
            addChapters(fileURL: url)
        }

        let metadata = items.filter { let ext = $0.pathExtension.lowercased(); return ext == "xml" ||  ext == "nfo" }
        if let url = metadata.first {
            addMetadata(fileURL: url)
        }

        let files = items.filter { MP42FileImporter.canInit(withFileType: $0.pathExtension) }
        if files.isEmpty == false {
            showImportSheet(fileURLs: files)
        }

        return true
    }

    // MARK: Keyboard navigation

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.utf16.first else { super.keyDown(with: event); return }

        if key == NSRightArrowFunctionKey || key == NSLeftArrowFunctionKey {
            let detailsItem = splitViewController.splitViewItems[1]
            if let propertyView = detailsItem.viewController.children.first as? PropertyView {
                propertyView.navigate(direction: Int(key))
            }
        } else {
            super.keyDown(with: event)
        }
    }


}
