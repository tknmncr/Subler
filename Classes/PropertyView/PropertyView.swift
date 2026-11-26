//
//  PropertyView.swift
//  Subler
//
//  Created by Damiano Galassi on 11/11/2019.
//

import Cocoa

class PropertyView : NSViewController {
    @IBOutlet var tabView: NSTabView?

    /// True when the view must be displayed but not edited (Matroska
    /// tags-only documents). Set by DocumentWindowController; subclasses that
    /// host tables or re-enable controls dynamically must honor it.
    var isReadOnly = false {
        didSet {
            if isViewLoaded, isReadOnly {
                view.setAllControlsEnabled(false)
            }
        }
    }

    /// Companion to `isReadOnly` for Matroska documents: the blanket disable
    /// still applies, but subclasses may re-enable the handful of controls
    /// whose values `MP42MkvTagWriter` can write back (currently the subtitle
    /// forced flag). Never consulted when `isReadOnly` is false.
    var allowsTrackEditing = false

    /// True when the document is a Matroska tags-only document. Unlike
    /// `isReadOnly` this is set on *every* property view — including the
    /// metadata tab, which stays editable — so views can visually flag the
    /// fields `MP42MkvTagWriter` cannot save. Subclasses override
    /// `updateMatroskaFieldHints()` to apply the styling.
    var isMatroskaDocument = false {
        didSet {
            if isViewLoaded, isMatroskaDocument != oldValue {
                updateMatroskaFieldHints()
            }
        }
    }

    /// Hook for `isMatroskaDocument` changes; called by subclasses after
    /// their views are loaded too. Default: nothing to flag.
    func updateMatroskaFieldHints() {}

    func navigate(direction: Int) {
        if direction == NSRightArrowFunctionKey {
            tabView?.selectNextTabViewItem(self)
        } else {
            tabView?.selectPreviousTabViewItem(self)
        }
    }

    func selectTabViewItem(at index: Int) {
        tabView?.selectTabViewItem(at: index)
    }

    func selectedViewIndex() -> Int {
        var index = NSNotFound
        if let item = tabView?.selectedTabViewItem {
            index = tabView?.indexOfTabViewItem(item) ?? NSNotFound
        }
        return index
    }
}
