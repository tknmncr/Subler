//
//  Document.swift
//  Subler
//
//  Created by Damiano Galassi on 10/02/2018.
//

import Cocoa
import IOKit.pwr_mgt
import MP42Foundation

@objc(SBDocument)
final class Document: NSDocument {

    private(set) var mp4: MP42File
    private var unsupportedMp4Brand: Bool

    // Matroska documents open in tags-only mode: the model is an in-memory
    // MP42File whose tracks are demuxed for display and whose metadata is
    // written back into the original file (Tags + cover attachment) by
    // MP42MkvTagWriter on save.
    private(set) var isMatroska = false
    private var mkvWriter: MP42MkvTagWriter?
    private var mkvRemuxer: MP42MkvRemuxer?
    // Tracks exactly as the importer produced them (file order, chapter
    // pseudo-track filtered): the baseline MP42MkvRemuxer pairs TrackEntry
    // elements against, so a deleted track is detected by object identity.
    private var mkvSourceTracks: [MP42Track] = []
    private var mkvFileSize: UInt64 = 0
    private var mkvFileModificationDate: Date?

    override init() {
        self.cancelled = false
        self.options = [:]
        self.optimize = false
        self.unsupportedMp4Brand = false
        self.mp4 = MP42File()
        super.init()
        self.mp4.undo = undoManager
    }

    init(mp4: MP42File) {
        self.cancelled = false
        self.options = [:]
        self.optimize = false
        self.unsupportedMp4Brand = false
        self.mp4 = mp4
        super.init()

        if let url = mp4.url {
            fileURL = url
        } else {
            updateChangeCount(.changeDone)
        }
        self.mp4.undo = undoManager
    }

    override func makeWindowControllers() {
        let documentWindowController = DocumentWindowController()
        addWindowController(documentWindowController)
        documentWindowController.showWindow(self)

        if let url = fileURL, unsupportedMp4Brand {
            // We can't edit this file, so ask the user if it wants to import it
            documentWindowController.showImportSheet(fileURLs: [url])
            fileURL = nil
        }
    }

    // MARK: Read

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { return true }

    override public var isEntireFileLoaded: Bool { get { return false } }

    override func read(from url: URL, ofType typeName: String) throws {
        if MP42FileImporter.isMatroskaFileType(url.pathExtension) {
            try readMatroska(from: url)
            return
        }

        do {
            mp4 = try MP42File(url: url)
            mp4.undo = undoManager
        } catch {
            unsupportedMp4Brand = true
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        if isMatroska || MP42FileImporter.isMatroskaFileType(url.pathExtension) {
            try readMatroska(from: url)
        } else {
            mp4 = try MP42File(url: url)
            mp4.undo = undoManager
        }

        if let docController = windowControllers.first as? DocumentWindowController {
            docController.reloadData()
            undoManager?.removeAllActions()
        }

        updateChangeCount(.changeCleared)
    }

    private func readMatroska(from url: URL) throws {
        // tagsOnly: the importer mirrors the file's own track flags instead of
        // applying the MP4 conversion heuristic, so the model matches the file
        // (MP42MkvTagWriter diffs track fields against it on save).
        let importer = try MP42FileImporter(url: url, tagsOnly: true)
        let file = MP42File()
        file.metadata.merge(importer.metadata, overwrite: true)
        var displayTrackId: MP42TrackId = 0
        for track in importer.tracks {
            // -[MP42File addTrack:] asserts that tracks whose codec cannot be
            // muxed into MP4 as-is (mp3, vorbis, srt, pgs, …) carry conversion
            // settings. Tags-only documents never mux these tracks, but
            // satisfy the invariant with the same defaults the convert-import
            // flow uses (see FileImportController.addTracks).
            if trackNeedConversion(track.format), track.isMember(of: MP42ChapterTrack.self) == false {
                switch track {
                case let audioTrack as MP42AudioTrack:
                    audioTrack.conversionSettings = MP42AudioConversionSettings.audioConversion(withBitRate: Prefs.audioBitrate,
                                                                                                 mixDown: MP42AudioMixdown(Prefs.audioMixdown),
                                                                                                 drc: Prefs.audioDRC)
                case let subtitleTrack as MP42SubtitleTrack:
                    subtitleTrack.conversionSettings = MP42ConversionSettings.subtitlesConversion()
                default:
                    break
                }
            }
            file.addTrack(track)
            // addTrack: zeroes trackId (pending-mux bookkeeping, the real
            // IDs come from the muxer) and tags-only documents are never
            // muxed, so assign display IDs 1-based like MKV players number
            // tracks. The chapter track is numbered too, matching how the
            // muxer would eventually number it.
            // (file.undo is not wired yet at this point, so this does not
            // open an undo group.)
            displayTrackId += 1
            track.trackId = displayTrackId
        }
        mp4 = file
        mp4.undo = undoManager
        isMatroska = true
        // Order-sensitive snapshot for the remuxer's TrackEntry pairing; the
        // chapter pseudo-track has no TrackEntry and must not shift positions.
        mkvSourceTracks = importer.tracks.filter { $0.isMember(of: MP42ChapterTrack.self) == false }
        snapshotMatroskaFile(at: url)
    }

    // The tag writer refuses to overwrite a file that changed on disk since
    // we read it; NSDocument doesn't perform that check for us here.
    private func snapshotMatroskaFile(at url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        mkvFileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        mkvFileModificationDate = attributes?[.modificationDate] as? Date
    }

    // MARK: Save

    override nonisolated class var autosavesInPlace: Bool { return false }

    private var optimize: Bool
    private var options: [String : Any]
    private var cancelled: Bool

    private func saveOptions(for saveOperation: NSDocument.SaveOperationType) -> [String : Any] {
        var options = [String : Any]()

        if Prefs.chaptersPreviewTrack {
            options[MP42GenerateChaptersPreviewTrack] = true
            options[MP42ChaptersPreviewPosition] = Prefs.chaptersPreviewPosition
        }

        if Prefs.forceHvc1 {
            options[MP42ForceHvc1] = true
        }

        if let accessoryViewController = accessoryViewController,
           saveOperation == .saveAsOperation || saveOperation == .saveToOperation {
            options[MP4264BitData] = accessoryViewController._64bit_data.state == .on ? true : false
            options[MP4264BitTime] = accessoryViewController._64bit_time.state == .on ? true : false
            optimize = accessoryViewController.optimize.state == .on ? true : false
        }

        return options
    }

    @IBAction func saveAndOptimize(_ sender: Any) {
        optimize = true
        save(self)
    }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { return true }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let docController = windowControllers.first as? DocumentWindowController

        let modifiedCompletionhandler = { (error: Error?) -> Void in
            docController?.endProgressReporting()

            if let error = error {
                completionHandler(error);
            } else if self.isMatroska {
                // The file was retagged in place; the tracks in the model are
                // still the ones on disk, so only the undo stack needs reset.
                self.undoManager?.removeAllActions()
                docController?.reloadData()
                completionHandler(error)
            } else {
                do {
                    let reloadedFile = try MP42File(url: url)
                    self.mp4 = reloadedFile
                    self.mp4.undo = self.undoManager
                    self.undoManager?.removeAllActions()
                    docController?.reloadData()
                    completionHandler(error)
                } catch {
                    completionHandler(error)
                }
            }
        }

        options = saveOptions(for: saveOperation)
        releaseSavePanel()

        docController?.startProgressReporting()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: modifiedCompletionhandler)
    }

    func cancelSave() {
        cancelled = true
        mkvWriter?.cancel()
        mkvRemuxer?.cancel()
        mp4.cancel()
    }

    private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionSuccess: IOReturn = kIOReturnInvalid

    private func preventSleep() {
        sleepAssertionSuccess = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Subler Save Operation" as CFString,
                                                  &sleepAssertion)
    }

    private func allowSleep() {
        if sleepAssertionSuccess == kIOReturnSuccess {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertionSuccess = kIOReturnInvalid
            sleepAssertion = IOPMAssertionID(0)
        }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        unblockUserInteraction()
        preventSleep()

        defer {
            allowSleep()
            optimize = false
            options = [:]
            mkvWriter = nil
            mkvRemuxer = nil
        }

        if isMatroska {
            try writeMatroska(to: url, for: saveOperation)
            cancelled = false
            return
        }

        if Prefs.organizeAlternateGroups {
            mp4.organizeAlternateGroups()
            if Prefs.inferMediaCharacteristics {
                mp4.inferTracksLanguages()
                mp4.inferMediaCharacteristics()
            }
        }

        switch saveOperation {
        case .saveOperation:
            try mp4.update(options: options)
        case .saveAsOperation:
            try mp4.write(to: url, options: options)
        default:
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The save operation is not supported.", comment: "Document unsupported save operation error.")])
        }

        if optimize && cancelled == false {
            DispatchQueue.main.async {
                let docController = self.windowControllers.first as? DocumentWindowController
                docController?.setProgress(title: NSLocalizedString("Optimizing…", comment: "Document Optimize sheet."))
            }
            mp4.optimize()
        }

        cancelled = false
    }

    private func writeMatroska(to url: URL, for saveOperation: NSDocument.SaveOperationType) throws {
        guard MP42FileImporter.isMatroskaFileType(url.pathExtension) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Matroska documents can only be saved as a .mkv, .mka or .mks file.", comment: "Document MKV save destination type error.")])
        }

        let currentTracks = mp4.tracks.filter { $0.isMember(of: MP42ChapterTrack.self) == false }
        // Structural change == some importer-created track is gone, or the
        // model carries a track the importer never produced (an imported
        // subtitle). Tracks are paired by object identity, so a reordered
        // (impossible: reorder is gated on MKV docs) or merely renamed track
        // still compares equal.
        let tracksChanged = currentTracks.count != mkvSourceTracks.count ||
            currentTracks.contains { track in mkvSourceTracks.contains(where: { $0 === track }) == false }

        if tracksChanged || saveOperation != .saveOperation {
            try remuxMatroska(to: url, currentTracks: currentTracks)
            return
        }

        let writer = MP42MkvTagWriter(url: url)
        writer.expectedFileSize = mkvFileSize
        writer.expectedModificationDate = mkvFileModificationDate
        // The save sheet listens on the model's progress handler (see
        // DocumentWindowController.startProgressReporting); forward through it.
        writer.progressHandler = { [weak self] progress in
            self?.mp4.progressHandler?(progress)
        }
        mkvWriter = writer
        // Track edits (name/language/enabled/subtitle forced) ride along; the
        // chapter pseudo-track is skipped by the writer.
        try writer.write(mp4.metadata, tracks: mp4.tracks)
        mkvWriter = nil
        // The file we just wrote is the new baseline for the staleness check.
        snapshotMatroskaFile(at: url)
    }

    // Stream-copy rebuild: blocks are copied verbatim except those of removed
    // tracks, and metadata/cover/track-field edits ride in the same pass.
    // Writes a temp file and renames atomically; see MP42MkvRemuxer.h.
    private func remuxMatroska(to url: URL, currentTracks: [MP42Track]) throws {
        guard let sourceURL = fileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The Matroska source file is unknown.", comment: "Document MKV remux missing source error.")])
        }
        let remuxer = MP42MkvRemuxer(sourceURL: sourceURL)
        remuxer.expectedFileSize = mkvFileSize
        remuxer.expectedModificationDate = mkvFileModificationDate
        remuxer.progressHandler = { [weak self] progress in
            self?.mp4.progressHandler?(progress)
        }
        mkvRemuxer = remuxer
        try remuxer.remux(to: url, metadata: mp4.metadata,
                          sourceTracks: mkvSourceTracks, currentTracks: currentTracks)
        mkvRemuxer = nil
        // The output keeps the surviving TrackEntry elements in source file
        // order and appends one TrackEntry per added subtitle track last
        // (MP42MkvRemuxer), so re-snapshot the pairing baseline in that same
        // order — otherwise the appended track would look "added" again on
        // the next save and the TrackEntry count would mispair.
        let addedTracks = currentTracks.filter { track in
            mkvSourceTracks.contains(where: { $0 === track }) == false
        }
        mkvSourceTracks = mkvSourceTracks.filter { track in
            currentTracks.contains(where: { $0 === track })
        } + addedTracks
        snapshotMatroskaFile(at: url)
    }

    // MARK: Save panel

    private var accessoryViewController: SaveOptions?

    override var shouldRunSavePanelWithAccessoryView: Bool { return false }
    
    override var savePanelShowsFileFormatsControl: Bool { return false }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        self.accessoryViewController = SaveOptions(doc: self, savePanel: savePanel)

        savePanel.isExtensionHidden = false
        savePanel.accessoryView = accessoryViewController?.view

        return true
    }

    private func releaseSavePanel() {
        accessoryViewController?.saveUserDefaults()
        accessoryViewController = nil
    }

    // MARK: Queue
    @IBAction func sendToQueue(_ sender: Any) {
        guard let windowForSheet = windowForSheet else { return }

        let queue = QueueController.shared
        if mp4.hasFileRepresentation {
            let item = QueueItem(mp4: mp4)
            queue.add(item, applyPreset: true)
            close()
        }
        else {
            let panel = NSSavePanel()
            panel.prompt = NSLocalizedString("Send To Queue", comment: "")

            let handler = { (response: NSApplication.ModalResponse) in
                if response == NSApplication.ModalResponse.OK, let url = panel.url {
                    let options = self.saveOptions(for: .saveAsOperation)
                    let item = QueueItem(mp4: self.mp4, destURL: url, attributes: options, optimize: self.optimize)
                    queue.add(item)
                    self.releaseSavePanel()
                    self.close()
                }
            }

            if prepareSavePanel(panel) {
                panel.beginSheetModal(for: windowForSheet, completionHandler: handler)
            }
        }
    }

    // MARK: User interface validation

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(revertToSaved(_:)) where isDocumentEdited == true:
            return true
        case #selector(save(_:)) where isDocumentEdited == true:
            return true
        case #selector(saveAs(_:)):
            // MKV Save-As runs through MP42MkvRemuxer (stream copy, same
            // container — the destination must stay .mkv/.mka/.mks, checked
            // in writeMatroska).
            return true
        case #selector(sendToQueue(_:)):
            return true
        case #selector(saveAndOptimize(_:)) where isDocumentEdited == false && mp4.hasFileRepresentation == true:
            return true
        default:
            return false
        }
    }

}
