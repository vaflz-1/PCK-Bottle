import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";

const tauriConfig = JSON.parse(
  readFileSync(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"),
);
const defaultCapability = JSON.parse(
  readFileSync(new URL("../src-tauri/capabilities/default.json", import.meta.url), "utf8"),
);
const buildScript = readFileSync(new URL("../src-tauri/build.rs", import.meta.url), "utf8");
const iconRoot = new URL("../src-tauri/icons/", import.meta.url);

// The native app was refactored from a single main.swift into several files in
// the same SwiftPM target. These contracts care about the app as a whole, so we
// assert against the concatenation of every Swift source in the target.
const nativeSourceRoot = new URL(
  "../../macos/PCKBottle/Sources/PCKBottleApp/",
  import.meta.url,
);
const nativeSource = readdirSync(nativeSourceRoot)
  .filter((name) => name.endsWith(".swift"))
  .sort()
  .map((name) => readFileSync(new URL(name, nativeSourceRoot), "utf8"))
  .join("\n\n");

test("Tauri build manifest explicitly exposes only the app IPC commands", () => {
  assert.match(buildScript, /AppManifest::new\(\)\.commands/);

  for (const command of [
    "scan_paths",
    "repack_pck",
    "open_pck_workspace",
    "cleanup_pck_workspace",
    "open_editor_window",
    "open_game_path_dialog",
  ]) {
    assert.match(buildScript, new RegExp(`"${command}"`));
  }
});

test("Tauri backend delegates reusable PCK behavior to the shared Rust core crate", () => {
  const cargoToml = readFileSync(new URL("../src-tauri/Cargo.toml", import.meta.url), "utf8");
  const tauriLib = readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8");

  assert.match(cargoToml, /godot-pck-core\s*=\s*\{\s*path\s*=\s*"..\/..\/crates\/pck-core"/);
  assert.match(tauriLib, /godot_pck_core::open_pck_workspace/);
  assert.match(tauriLib, /godot_pck_core::repack_pck/);
  assert.doesNotMatch(tauriLib, /const PCK_HEADER_MAGIC/);
});

test("native macOS shell scaffold stays AppKit-first and High Sierra compatible", () => {
  const shellRoot = new URL("../../macos/PCKBottle/", import.meta.url);
  const packageManifestUrl = new URL("Package.swift", shellRoot);
  const readmeUrl = new URL("README.md", shellRoot);
  const mainSwiftUrl = new URL("Sources/PCKBottleApp/main.swift", shellRoot);

  assert.equal(existsSync(packageManifestUrl), true);
  assert.equal(existsSync(readmeUrl), true);
  assert.equal(existsSync(mainSwiftUrl), true);

  const packageManifest = readFileSync(packageManifestUrl, "utf8");
  const readme = readFileSync(readmeUrl, "utf8");
  const mainSwift = readFileSync(mainSwiftUrl, "utf8");

  assert.match(packageManifest, /platforms:\s*\[\s*\.macOS\(\.v10_13\)\s*\]/);
  assert.match(mainSwift, /import AppKit/);
  assert.match(mainSwift, /NSWindowController/);
  assert.match(mainSwift, /NSSplitViewController/);
  assert.doesNotMatch(mainSwift, /SwiftUI/);
  assert.match(readme, /template assets/i);
  assert.doesNotMatch(readme, /Jenkins/i);
});

test("native macOS shell has a repeatable universal app bundle builder", () => {
  const buildScriptUrl = new URL("../../macos/PCKBottle/scripts/build-app.sh", import.meta.url);

  assert.equal(existsSync(buildScriptUrl), true);

  const buildScript = readFileSync(buildScriptUrl, "utf8");

  assert.match(buildScript, /swift build[^\n]+--arch arm64[^\n]+--arch x86_64/);
  assert.match(buildScript, /cargo build[^\n]+--bin pck-core-cli[^\n]+--target "\$target"/);
  assert.match(buildScript, /aarch64-apple-darwin/);
  assert.match(buildScript, /x86_64-apple-darwin/);
  assert.match(buildScript, /lipo -create/);
  assert.match(buildScript, /RESOURCES_DIR\/pck-core-cli/);
  assert.match(buildScript, /PCK Bottle\.app/);
  assert.match(buildScript, /LSMinimumSystemVersion/);
  assert.match(buildScript, /10\.13/);
  assert.doesNotMatch(buildScript, /Jenkins/i);
});

test("native macOS bundle packages a real app icon", () => {
  const buildScript = readFileSync(
    new URL("../../macos/PCKBottle/scripts/build-app.sh", import.meta.url),
    "utf8",
  );
  const iconPath = new URL("../../macos/PCKBottle/Assets/PCKBottle.icns", import.meta.url);

  assert.equal(statSync(iconPath).isFile(), true);
  assert.match(buildScript, /ICON_FILE=.*PCKBottle\.icns/);
  assert.match(buildScript, /cp "\$ICON_FILE" "\$RESOURCES_DIR\/PCKBottle\.icns"/);
  assert.match(buildScript, /CFBundleIconFile/);
  assert.match(buildScript, /PCKBottle\.icns/);
});

test("native macOS app keeps the beta runtime lightweight", () => {
  const packageManifest = readFileSync(
    new URL("../../macos/PCKBottle/Package.swift", import.meta.url),
    "utf8",
  );
  const buildScript = readFileSync(
    new URL("../../macos/PCKBottle/scripts/build-app.sh", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(packageManifest, /dependencies:\s*\[/);
  assert.doesNotMatch(packageManifest, /Quasar|Vue|Tauri|JavaScript/i);
  assert.match(buildScript, /cp "\$BINARY_PATH" "\$MACOS_DIR\/PCKBottle"/);
  assert.match(buildScript, /cp "\$CORE_CLI_PATH" "\$RESOURCES_DIR\/pck-core-cli"/);
  assert.match(buildScript, /swift-stdlib-tool/);
  assert.match(buildScript, /LIB_DIR="\$CONTENTS_DIR\/lib"/);
  assert.doesNotMatch(buildScript, /node_modules|quasar|vue|tauri/i);
});

test("native macOS browser implements the first usable .app and .pck workflow", () => {
  const mainSwift = nativeSource;

  for (const requiredPattern of [
    /NSOpenPanel/,
    /allowedFileTypes\s*=\s*\[\s*"app",\s*"pck"\s*\]/,
    /registerForDraggedTypes\(\[\.fileURL\]\)/,
    /func draggingEntered\(/,
    /func performDragOperation\(/,
    /func scanForPackages/,
    /scanSiblingPackagesForAppBundle/,
    /isDirectPckSelection/,
    /packages\.count == 1/,
    /NSTableViewDataSource/,
    /NSTableViewDelegate/,
    /NSButton\(title:\s*"Open Game or PCK"/,
    /EditorWindowController/,
    /openSelectedPackage/,
    /doubleAction\s*=\s*#selector\(openSelectedPackage/,
    /Choose a \.pck in Packages/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  assert.doesNotMatch(mainSwift, /PlaceholderPaneViewController/);
});

test("native macOS app exposes Finder-style menu commands and selection shortcuts", () => {
  const mainSwift = nativeSource;

  for (const requiredPattern of [
    /func installMainMenu/,
    /NSApp\.mainMenu/,
    /NSMenuItem\(title:\s*"Select All"/,
    /selectAll:/,
    /keyEquivalent:\s*"a"/,
    /NSMenuItem\(title:\s*"Open"/,
    /keyEquivalent:\s*"o"/,
    // Undo/Redo are vended through the responder chain to the editor window.
    /NSSelectorFromString\("undo:"\)/,
    /NSSelectorFromString\("redo:"\)/,
    /override func selectAll/,
    /(?:outlineView|tableView)\.selectAll/,
    /allowsMultipleSelection\s*=\s*true/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }
});

test("native macOS editor projects staged changes optimistically with undo and drag-out", () => {
  const mainSwift = nativeSource;

  // B. Optimistic projection: the tree shows the projected result of the staged
  // ops over an immutable loaded listing — no disk writes until Pack.
  for (const requiredPattern of [
    /loadedEntries/,
    /func rebuildProjection\(animated: Bool = false\)/,
    /buildProjectedTree\(/,
    /var tint: PendingTint/,
    /enum PendingTint/,
    /label\.textColor = node\.tint\.color/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // C. Undo/redo via NSUndoManager, vended by the editor window.
  for (const requiredPattern of [
    /func windowWillReturnUndoManager\(_ window: NSWindow\) -> UndoManager\?/,
    /UndoManager\(\)/,
    /func mutateStagedOperations\(actionName:/,
    /undoManager\.registerUndo\(withTarget: self\)/,
    /undoManager\.setActionName/,
    /localized\("undoDelete"\)/,
    /localized\("undoDuplicate"\)/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // D. Keyboard shortcuts on the tree subclass.
  for (const requiredPattern of [
    /final class PackageOutlineView: NSOutlineView/,
    /override func performKeyEquivalent\(with event: NSEvent\)/,
    /override func keyDown\(with event: NSEvent\)/,
    /NSDeleteCharacter/,
    /onDelete/,
    /onDuplicate/,
    /onCopy/,
    // ⌘V pastes file URLs from the clipboard as the counterpart to ⌘C.
    /onPaste/,
    /func pasteFromClipboard\(\)/,
    /localized\("menuPaste"\)/,
    /onExtract/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // D2. The projection refresh animates per-row: deletes/undos slide rows out,
  // adds/pastes/redos slide them in, instead of a hard reload. Undo/redo reuse
  // the same animated path so ⌘Z is animated too.
  for (const requiredPattern of [
    /func rebuildProjection\(animated: Bool = false\)/,
    /func mutateStagedOperations\(actionName: String, animated: Bool = false/,
    /removeItems\(at: entry\.indexes, inParent: entry\.parent, withAnimation:/,
    /outlineView\.insertItems\(at: IndexSet\(integer: index\), inParent: parent, withAnimation:/,
    /target\.updateChangesUI\(animated: animated\)/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // D3. Paste keeps both copies (rename on collision) rather than replacing, and
  // a backup can be restored from the File menu.
  for (const requiredPattern of [
    /uniqueDuplicateTarget\(for: target, additionalTaken: usedTargets\)/,
    /action: \.addNew/,
    /func restoreBackupFromMenu\(_ sender: Any\?\)/,
    /func latestBackupURL\(\) -> URL\?/,
    /replaceItemAt\(destination, withItemAt: staging\)/,
    /localized\("restoreBackup"\)/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // E. Real drag-OUT to Finder via file promises (still uses extract-paths).
  for (const requiredPattern of [
    /NSFilePromiseProviderDelegate/,
    /func outlineView\(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any\)/,
    /NSFilePromiseProvider\(fileType:/,
    /writePromiseTo url: URL/,
    /setDraggingSourceOperationMask\(\.copy, forLocal: false\)/,
    /PckCoreClient\.extractPaths/,
    /\["extract-paths", packageURL\.path, destinationURL\.path\]/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // H. Right-click selects the clicked row without scrolling it into view.
  assert.match(mainSwift, /override func menu\(for event: NSEvent\) -> NSMenu\?/);
  assert.doesNotMatch(mainSwift, /scrollRowToVisible/);
});

test("native macOS editor reviews staged changes in a collapsible grouped Changes panel", () => {
  const mainSwift = nativeSource;
  // The redesigned editor is a two-column [package tree | Changes] layout. Staged
  // work is reviewed in a Changes panel that groups operations by kind into
  // collapsible sections and hosts the Pack + Backup controls.
  const changesPaneMatch = mainSwift.match(
    /final class ChangesViewController[\s\S]+?final class PackageOutlineView/,
  );
  assert.ok(changesPaneMatch, "ChangesViewController block should be present");
  const changesPane = changesPaneMatch[0];

  for (const requiredPattern of [
    /NSTableViewDataSource/,
    /NSTableViewDelegate/,
    // The grouped panel renders via an inner NSOutlineView of kind sections.
    /NSOutlineViewDataSource/,
    /NSOutlineViewDelegate/,
    /ChangeGroup\(action:/,
    /func rebuildGroups\(\)/,
    /func outlineView\(_ outlineView: NSOutlineView, isItemExpandable item: Any\)/,
    /expandItem\(group\)/,
    /weak var controller: PackageContentsViewController\?/,
    /func render\(operations:\s*\[StagedOperationRecord\]\)/,
    /warningBanner/,
    /localized\("changes"\)/,
    /localized\("changesEmptyHint"\)/,
    /localized\("noMatchWarning"\)/,
    /localized\("groupReplace"/,
    /localized\("groupAdd"/,
    /localized\("groupDelete"/,
    /localized\("groupDuplicate"/,
    // Per-row kind badges were removed (the group header already names the kind);
    // rows now carry only a small accent dot + path + source. The user's manual
    // collapse of a group must survive subsequent staging actions.
    /collapsedActions/,
    /outlineViewItemDidCollapse/,
    /func applyExpansionState\(\)/,
    /Backup original/,
    /Pack Changes/,
    // The backup checkbox now has a visible, separate label (was invisible).
    /backupLabel/,
    /removeClickedRow/,
    /localized\("remove"\)/,
    /removeStagedOperations/,
    // Restored regression: the Changes pane is itself a drop target for external
    // file URLs, forwarding them to the controller to stage as ADDs.
    /onURLsDropped/,
    /stageExternalURLs/,
  ]) {
    assert.match(changesPane, requiredPattern);
  }

  // The grouped-changes model types back the collapsible sections and per-row
  // removal mapping.
  assert.match(mainSwift, /final class ChangeGroup/);
  assert.match(mainSwift, /final class ChangeOperationRow/);

  // The Changes pane container registers external file URL drops and reuses the
  // tree's smart folder mapping (expandExternalSourceURL) — no reimplemented
  // path logic.
  assert.match(mainSwift, /class ChangesDropContainerView/);
  assert.match(mainSwift, /registerForDraggedTypes\(\[\.fileURL\]\)/);
  assert.match(mainSwift, /func stageExternalURLs\(_ urls: \[URL\]\)/);
  assert.match(mainSwift, /expandExternalSourceURL/);

  // Regression guard: folder staging MUST NOT skip hidden files, or Godot's
  // imported textures under res://.import (Godot 3 .stex) / res://.godot
  // (Godot 4 .ctex) get silently dropped and localized graphics never pack.
  // Hidden dirs must be walked; only OS/VCS junk is excluded.
  const expandFn = mainSwift.match(
    /private static func expandExternalSourceURL[\s\S]+?\n    \}/,
  );
  assert.ok(expandFn, "expandExternalSourceURL should be present");
  // The staging enumerator must not be configured to skip hidden files.
  assert.doesNotMatch(expandFn[0], /options:\s*\[\.skipsHiddenFiles\]/);
  assert.match(expandFn[0], /options:\s*\[\],/);
  assert.match(mainSwift, /func isPackagingJunk\(_ url: URL\) -> Bool/);
  assert.match(mainSwift, /\.DS_Store/);

  // Regression: a dropped folder must KEEP its own name (root = parent), so
  // nesting like scenarios/ is preserved instead of being flattened to root.
  // A pure distribution wrapper (translation/) is unwrapped separately, keyed
  // on the package's real top-level folders.
  assert.match(expandFn[0], /root: nameRoot/);
  assert.doesNotMatch(expandFn[0], /root: url\)/);
  assert.match(mainSwift, /func unwrapWrapperPrefixes\(_ paths: \[String\]\) -> \[String\]/);
  assert.match(mainSwift, /packageTopLevels/);

  // The internal source drag payload reader still backs the package-tree drop.
  assert.match(mainSwift, /SourceDragPayloadGroup:\s*Codable/);

  // The removed sidebar view controllers must not reappear.
  assert.doesNotMatch(mainSwift, /class SourceFilesViewController/);
  assert.doesNotMatch(mainSwift, /class ExportFolderViewController/);
  assert.doesNotMatch(mainSwift, /class EditorSidebarViewController/);
});

test("native macOS editor lists pck contents quickly without extracting on open", () => {
  const mainSwift = nativeSource;
  const coreCli = readFileSync(
    new URL("../../crates/pck-core/src/bin/pck-core-cli.rs", import.meta.url),
    "utf8",
  );

  for (const requiredPattern of [
    /editorWindowsByPath:\s*\[String:\s*EditorWindowController\]/,
    /makeKeyAndOrderFront/,
    /windowWillClose/,
    /ChangesViewController/,
    /PackageContentsViewController/,
    /NSOutlineViewDataSource/,
    /NSOutlineViewDelegate/,
    /func loadPackageContents/,
    /pck-core-cli/,
    /list-pck/,
    /JSONDecoder\(\)\.decode\(PckListingPayload\.self/,
    /PackageTreeNode/,
    /outlineView\(/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  assert.match(coreCli, /Some\("list-pck"\)/);
  assert.match(coreCli, /godot_pck_core::list_pck_entries/);
  assert.match(coreCli, /serde_json::to_writer/);
  assert.doesNotMatch(mainSwift, /workspace\.extractPath/);
  assert.doesNotMatch(mainSwift, /Drop modification files here in the next slice/);
});

test("native macOS editor exposes real file staging, backup, progress, and repack", () => {
  const mainSwift = nativeSource;
  const coreCli = readFileSync(
    new URL("../../crates/pck-core/src/bin/pck-core-cli.rs", import.meta.url),
    "utf8",
  );

  for (const requiredPattern of [
    /SourceDragPayload:\s*Codable/,
    /StagedOperationRecord/,
    /registerForDraggedTypes\(\[\.pckBottleSourceItems,\s*\.pckBottleSourceItem,\s*\.fileURL\]\)/,
    /validateDrop/,
    /acceptDrop/,
    /Pack Changes/,
    /Backup original/,
    /NSProgressIndicator/,
    /func packChanges/,
    /readStagedItems/,
    /existingPackagePaths/,
    /action:\s*stageAction/,
    /Replace existing/,
    /Add new/,
    /stageTarget/,
    /confirmPackChanges/,
    /summarizePackResult/,
    /PckCoreClient\.repack/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  assert.match(coreCli, /Some\("repack"\)/);
  assert.match(coreCli, /serde_json::from_reader\(std::io::stdin\(\)\)/);
  assert.match(coreCli, /godot_pck_core::repack_pck/);
  // Subprocess args are now assembled inside PckCoreClient (array form, no shell).
  assert.match(nativeSource, /\["repack", packageURL\.path, backupOriginal \? "true" : "false"\]/);
});

test("native macOS pck contents are shown as a Finder-like package place", () => {
  const mainSwift = nativeSource;
  const packagePaneMatch = mainSwift.match(
    /final class PackageContentsViewController[\s\S]+/,
  );
  assert.ok(packagePaneMatch, "PackageContentsViewController block should be present");
  const packagePane = packagePaneMatch[0];

  for (const requiredPattern of [
    /packageRootTitle/,
    /packageRootSubtitle/,
    /rootNode = PackageTreeNode\(name: "Package root"/,
    /func outlineView\(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any\?\) -> Int[\s\S]+return item == nil \? 1/,
    /func outlineView\(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any\?\) -> Any[\s\S]+return rootNode/,
    /outlineView\.expandItem\(rootNode,\s*expandChildren:\s*false\)/,
    /packageNodeTitle/,
    /iconTextCell\(tableView:\s*outlineView/,
    /Package root/,
  ]) {
    assert.match(packagePane, requiredPattern);
  }
});

test("native macOS pck folders use Finder folder icons instead of document icons", () => {
  const mainSwift = nativeSource;
  const iconHelperMatch = mainSwift.match(
    /private func packageIcon\(for node: PackageTreeNode\) -> NSImage[\s\S]+?^}/m,
  );
  assert.ok(iconHelperMatch, "package icon helper should be present");
  const iconHelper = iconHelperMatch[0];

  assert.match(iconHelper, /node\.isDirectory/);
  assert.match(iconHelper, /NSFileTypeForHFSTypeCode/);
  assert.match(iconHelper, /kGenericFolderIcon/);
  assert.match(mainSwift, /iconView\.image = packageIcon\(for: node\)/);
  assert.doesNotMatch(iconHelper, /icon\(forFileType:\s*"folder"\)/);
});

test("native macOS editor keeps the Changes column stable while the pck tree resizes", () => {
  const mainSwift = nativeSource;

  // The editor is now a [package tree (LEFT, hero) | Changes (RIGHT)] split: the
  // tree is added first and flexes, while the Changes column has a bounded width
  // and high holding priority so it stays put while the tree absorbs resizing.
  assert.match(mainSwift, /let contentsItem = NSSplitViewItem\(viewController: packageContents\)/);
  assert.match(mainSwift, /contentsItem\.holdingPriority = \.defaultLow/);
  assert.match(mainSwift, /let changesItem = NSSplitViewItem\(viewController: changes\)/);
  assert.match(mainSwift, /changesItem\.holdingPriority = \.defaultHigh/);
  assert.match(mainSwift, /changesItem\.canCollapse = false/);

  // The tree (contents) is now the LEFT/hero pane: it is added before changes.
  assert.match(
    mainSwift,
    /addSplitViewItem\(contentsItem\)\s*\n\s*addSplitViewItem\(changesItem\)/,
  );

  // The legacy fixed-width sidebar constant is retired.
  assert.doesNotMatch(mainSwift, /editorSidebarWidth/);
});

test("native macOS editor keeps localized sidebar text inside visible bounds", () => {
  const mainSwift = nativeSource;
  const editorWindowMatch = mainSwift.match(/final class EditorWindowController[\s\S]+?final class EditorViewController/m);
  assert.ok(editorWindowMatch, "EditorWindowController block should be present");
  const editorWindow = editorWindowMatch[0];

  assert.match(editorWindow, /width: 1320,\s*height: 760/);
  assert.match(editorWindow, /contentMinSize = NSSize\(width: 1120,\s*height: 620\)/);
  assert.match(mainSwift, /drawCenteredDropTitle/);
  assert.match(mainSwift, /bounds\.insetBy\(dx: 18,\s*dy: 12\)/);
  assert.match(mainSwift, /\.usesLineFragmentOrigin/);
  // Long titles/status text (e.g. full PCK paths in pack results) must truncate
  // rather than stretch the editor window.
  assert.match(mainSwift, /titleLabel\.setContentCompressionResistancePriority\(\.defaultLow, for: \.horizontal\)/);
  assert.match(mainSwift, /statusLabel\.setContentCompressionResistancePriority\(\.defaultLow, for: \.horizontal\)/);
});

test("native macOS editor extracts pck items via a right-click context menu", () => {
  const mainSwift = nativeSource;
  const coreCli = readFileSync(
    new URL("../../crates/pck-core/src/bin/pck-core-cli.rs", import.meta.url),
    "utf8",
  );

  // Extraction is now triggered from an NSMenu on the package outline ("Extract
  // to…") operating on the clicked row + current multi-selection, then choosing
  // a destination via NSOpenPanel. It still funnels through PckCoreClient with
  // the same array-arg subprocess contract (no shell, no drag-out pasteboard).
  // The context menu also offers move/copy/duplicate/delete operations.
  for (const requiredPattern of [
    /outlineView\.menu = makeOutlineMenu\(\)/,
    /localized\("extractTo"\)/,
    /localized\("menuExtract"\)/,
    /localized\("menuMove"\)/,
    /localized\("menuCopy"\)/,
    /localized\("menuDuplicate"\)/,
    /localized\("menuDelete"\)/,
    /extractClickedItems/,
    /moveClickedItems/,
    /copyClickedItems/,
    /duplicateClickedItems/,
    /deleteClickedItems/,
    /outlineView\.clickedRow/,
    /outlineView\.selectedRowIndexes/,
    /NSOpenPanel\(\)/,
    /extractSelectedPackageItems/,
    /packageExportPaths/,
    /PckCoreClient\.extractPaths/,
    /\["extract-paths", packageURL\.path, destinationURL\.path\]/,
    /extract-paths/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // Copy puts extracted file URLs on the system pasteboard (non-destructive).
  assert.match(mainSwift, /NSPasteboard\.general/);
  assert.match(mainSwift, /clearContents\(\)/);
  assert.match(mainSwift, /writeObjects\(urls as \[NSURL\]\)/);

  // Move and Delete remove entries from the package via staged delete ops, and
  // Duplicate clones an existing entry via a staged copy op — all applied on
  // Pack through PckCoreClient.repack like add/replace.
  assert.match(mainSwift, /stageDeletes/);
  assert.match(mainSwift, /action:\s*\.delete/);
  assert.match(mainSwift, /action:\s*\.duplicate/);
  assert.match(mainSwift, /case \.delete:\s*\n\s*return "delete"/);
  assert.match(mainSwift, /case \.duplicate:\s*\n\s*return "copy"/);
  assert.match(mainSwift, /kind:\s*record\.action\.coreKind/);
  assert.match(mainSwift, /PckCoreClient\.repack/);

  // The retired drag-out export surface must not come back.
  assert.doesNotMatch(mainSwift, /Open Export Folder/);
  assert.doesNotMatch(mainSwift, /Drop PCK files here to extract/);
  assert.doesNotMatch(mainSwift, /PckExportPayload/);
  assert.doesNotMatch(mainSwift, /pckBottlePackageItems/);

  assert.match(coreCli, /Some\("extract-paths"\)/);
  assert.match(coreCli, /godot_pck_core::extract_pck_paths/);
  assert.match(coreCli, /serde_json::from_reader\(std::io::stdin\(\)\)/);
});

test("native macOS exposes a menu-bar Language switcher for Russian, English, and Chinese", () => {
  const mainSwift = nativeSource;

  for (const requiredPattern of [
    /enum AppLocale:\s*String,\s*CaseIterable/,
    /case ru/,
    /case en/,
    /case zh/,
    // The language picker now lives in the app main menu, not an in-window globe.
    /func makeLanguageMenu\(target: AnyObject, action: Selector\) -> NSMenu/,
    /languageMenuItem/,
    /rebuildLanguageMenu/,
    /selectLanguage/,
    /applySelectedLanguage/,
    /UserDefaults\.standard/,
    /pckBottleLanguageDidChange/,
    /applyLocalization/,
    /localized\(/,
    /Русский/,
    /English/,
    /中文/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  // The retired in-window globe button must not come back.
  assert.doesNotMatch(mainSwift, /makeGlobeLanguageButton/);
  assert.doesNotMatch(mainSwift, /🌐/);
});

test("native macOS pack flow keeps editor window geometry stable", () => {
  const mainSwift = nativeSource;

  for (const requiredPattern of [
    /preservedEditorWindowFrame/,
    /view\.window\?\.frame/,
    /restorePreservedEditorWindowFrame/,
    /window\.setFrame\(frame,\s*display:\s*true\)/,
    /progressIndicator\.isHidden = false/,
    /progressIndicator\.alphaValue = isPacking \? 1 : 0/,
    /statusLabel\.maximumNumberOfLines = 1/,
    /lineBreakMode = \.byTruncatingMiddle/,
  ]) {
    assert.match(mainSwift, requiredPattern);
  }

  assert.doesNotMatch(mainSwift, /progressIndicator\.isHidden = !isPacking/);
});

test("Tauri capability does not expose unused frontend permissions", () => {
  assert.equal(defaultCapability.permissions.includes("dialog:allow-save"), false);
  assert.equal(
    defaultCapability.permissions.includes("core:webview:allow-create-webview-window"),
    false,
  );
});

test("Tauri capability explicitly allows every frontend IPC command", () => {
  for (const permission of [
    "allow-scan-paths",
    "allow-repack-pck",
    "allow-open-pck-workspace",
    "allow-cleanup-pck-workspace",
    "allow-open-editor-window",
    "allow-open-game-path-dialog",
  ]) {
    assert.equal(defaultCapability.permissions.includes(permission), true);
  }
});

test("Tauri CSP denies unused document and embedding surfaces", () => {
  const csp = tauriConfig.app.security.csp;

  for (const directive of [
    "object-src 'none'",
    "base-uri 'none'",
    "frame-src 'none'",
    "form-action 'none'",
  ]) {
    assert.match(csp, new RegExp(`${directive.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  }
});

test("Tauri bundle references only the macOS icon assets it packages", () => {
  assert.deepEqual(tauriConfig.bundle.targets, ["app", "dmg"]);
  assert.deepEqual(tauriConfig.bundle.icon, [
    "icons/32x32.png",
    "icons/128x128.png",
    "icons/128x128@2x.png",
    "icons/icon.icns",
  ]);
});

test("Tauri icon directory contains only configured macOS bundle icons", () => {
  assert.deepEqual(readRelativeFiles(iconRoot), [
    "128x128.png",
    "128x128@2x.png",
    "32x32.png",
    "icon.icns",
  ]);
});

function readRelativeFiles(rootUrl, baseUrl = rootUrl) {
  return readdirSync(rootUrl)
    .flatMap((name) => {
      const childUrl = new URL(`${name}${statSync(new URL(name, rootUrl)).isDirectory() ? "/" : ""}`, rootUrl);
      if (statSync(childUrl).isDirectory()) {
        return readRelativeFiles(childUrl, baseUrl);
      }
      return [decodeURIComponent(childUrl.pathname.replace(baseUrl.pathname, ""))];
    })
    .sort();
}
