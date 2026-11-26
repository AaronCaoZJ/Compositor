import CoreGraphics
import Foundation

/// Camera Raw's RAW section: the controls a RAW file is developed with, for a layer whose pixels are still what the
/// file developed to (`RawOrigin`, `FilterEdit.rawSettings`). Moving one develops the file again, and the rest of the
/// panel is then applied to that develop in the layer's place.
extension EditorSession {
    /// A change to what the layer's file is developed with. A draft of the new develop shows at once, about 10 ms to
    /// make; the whole frame follows when the control rests, as the panel's own previews do (`FilterEdit.draft`).
    func updateCameraRawDevelop(_ change: (inout RawDevelopSettings) -> Void) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing, var settings = edit.rawSettings else { return }
        change(&settings)
        guard settings != edit.rawSettings else { return }
        edit.rawSettings = settings
        // What is on its way was for an older develop.
        edit.rawFullTask?.cancel()
        edit.refineTask?.cancel()
        developCameraRawDraft(edit)
    }

    /// One develop at a time, the newest settings next, as `renderFilterPreview` renders.
    private func developCameraRawDraft(_ edit: FilterEdit) {
        guard filterEdit === edit, !edit.committing, edit.rawDraftTask == nil, let developer = edit.rawDeveloper,
              let wanted = edit.rawSettings else { return }
        // A layer small enough to have no draft is developed whole each time.
        guard edit.draft != nil, edit.rawDraftSettings != wanted else { developCameraRawWhole(edit); return }
        edit.rawDraftTask = Task { @MainActor [weak self, weak edit] in
            let image = await developer.develop(wanted, limit: FilterEdit.draftLimit)
            guard let self, let edit, self.filterEdit === edit, !edit.committing, !Task.isCancelled else { return }
            edit.rawDraftTask = nil
            if let image {
                edit.takeRawDraft(image, developedWith: wanted)
                self.updateFilter(edit.settings, preview: edit.preview)
            }
            if edit.rawSettings != wanted { self.developCameraRawDraft(edit) } else { self.developCameraRawWhole(edit) }
        }
    }

    /// The whole frame developed with what the RAW section asks for, once its controls have rested: about 0.2 s for
    /// 42 megapixels. It becomes what the panel's previews are made from, the draft's included.
    private func developCameraRawWhole(_ edit: FilterEdit) {
        guard filterEdit === edit, !edit.committing, let developer = edit.rawDeveloper, let wanted = edit.rawSettings,
              edit.rawSourceSettings != wanted else { return }
        // With no draft to show meanwhile, only long enough to take the newest of a drag's changes.
        let rest = edit.draft != nil ? FilterEdit.refineDelay : .milliseconds(30)
        edit.rawFullTask?.cancel()
        edit.rawFullTask = Task { @MainActor [weak self, weak edit] in
            try? await Task.sleep(for: rest)
            guard !Task.isCancelled, let self, let edit, self.filterEdit === edit, !edit.committing,
                  edit.rawSettings == wanted else { return }
            let image = await developer.develop(wanted)
            guard !Task.isCancelled, self.filterEdit === edit, !edit.committing, edit.rawSettings == wanted, let image else { return }
            do { try edit.takeRawSource(image, developedWith: wanted) }
            catch { self.brushError = error.localizedDescription; return }
            // The controls rested for this develop, so the whole frame is rendered straight away in place of the
            // draft showing, which was of these settings too. A render still going leads to it by itself.
            if edit.preview, edit.preparedPreview != nil, edit.pending == nil, edit.previewTask == nil {
                self.refineFilterPreview(edit, after: .zero)
            } else {
                self.updateFilter(edit.settings, preview: edit.preview)
            }
        }
    }
}
