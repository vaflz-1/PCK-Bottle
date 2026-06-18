import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

import {
  buildTree,
  classifyGameOpen,
  createEditorSession,
  createStageOperation,
  createStageOperationAtPath,
  describeDragStack,
  describePackProgress,
  detectGodotTargets,
  filterProjectEntries,
  markStageOperationActions,
  mergeContentEntriesWithOperations,
  normalizePckTarget,
  nativeDropActionForMode,
  sourceSelectionAfterClick,
  sourceSelectionAfterSelectAll,
  sourceSelectionForDrag,
  stageOperationsForSourcePaths,
  sourceTransferIndex,
  shouldRerenderAfterPckSelect,
  summarizeOperations,
} from "../src/core/file-workflow.js";

test("buildTree creates a sorted explorer tree from flat paths", () => {
  const tree = buildTree([
    { path: "locale/ru.po", size: 1200 },
    { path: "assets/ui/menu.png", size: 420 },
    { path: "README.txt", size: 40 },
  ]);

  assert.equal(tree.children[0].name, "assets");
  assert.equal(tree.children[0].children[0].name, "ui");
  assert.equal(tree.children[1].name, "locale");
  assert.equal(tree.children[2].name, "README.txt");
});

test("detectGodotTargets finds pck files inside macOS app bundles and loose folders", () => {
  const targets = detectGodotTargets([
    {
      path: "The Case of the Golden Idol.app/Contents/Resources/game.pck",
      absolutePath: "/Applications/The Case of the Golden Idol.app/Contents/Resources/game.pck",
      size: 100,
    },
    { path: "The Case of the Golden Idol.app/Contents/MacOS/runner", size: 10 },
    { path: "mods/russian_patch.pck", size: 20 },
  ]);

  assert.deepEqual(
    targets.map((target) => ({
      appName: target.appName,
      pckPath: target.pckPath,
      absolutePath: target.absolutePath,
      kind: target.kind,
    })),
    [
      {
        appName: "The Case of the Golden Idol.app",
        pckPath: "The Case of the Golden Idol.app/Contents/Resources/game.pck",
        absolutePath: "/Applications/The Case of the Golden Idol.app/Contents/Resources/game.pck",
        kind: "mac-app",
      },
      {
        appName: "Loose folder",
        pckPath: "mods/russian_patch.pck",
        absolutePath: "mods/russian_patch.pck",
        kind: "folder",
      },
    ],
  );
});

test("classifyGameOpen opens a directly selected pck without replacing the game browser", () => {
  const result = classifyGameOpen([
    {
      path: "The Case of The Golden Idol.pck",
      absolutePath: "/Games/The Case of The Golden Idol.pck",
      size: 100,
    },
  ]);

  assert.equal(result.kind, "direct-pck");
  assert.equal(result.targets[0].absolutePath, "/Games/The Case of The Golden Idol.pck");
});

test("classifyGameOpen keeps an app selection in the browser flow", () => {
  const result = classifyGameOpen([
    {
      path: "The Case of The Golden Idol.app/Contents/Resources/game.pck",
      absolutePath: "/Games/The Case of The Golden Idol.app/Contents/Resources/game.pck",
      size: 100,
    },
  ]);

  assert.equal(result.kind, "game-browser");
});

test("filterProjectEntries searches the game tree for a specific pck", () => {
  const entries = [
    { path: "Game.app/Contents/Resources/game.pck", size: 100 },
    { path: "Game.app/Contents/Resources/audio.pck", size: 200 },
    { path: "Game.app/Contents/Info.plist", size: 40 },
  ];

  assert.deepEqual(
    filterProjectEntries(entries, "audio").map((entry) => entry.path),
    ["Game.app/Contents/Resources/audio.pck"],
  );
});

test("pck tree selection can update highlights without rerendering open folders", () => {
  assert.equal(shouldRerenderAfterPckSelect({ rerender: false }), false);
  assert.equal(shouldRerenderAfterPckSelect({}), true);
  assert.equal(shouldRerenderAfterPckSelect(), true);
});

test("createEditorSession keeps the selected pck and its visible content tree", () => {
  const [target] = detectGodotTargets([
    {
      path: "Game.app/Contents/Resources/game.pck",
      absolutePath: "/Games/Game.app/Contents/Resources/game.pck",
      size: 4096,
    },
  ]);

  const session = createEditorSession(target, [
    { path: "project.godot", size: 50 },
    { path: "locale/ru.po", size: 1200 },
  ], {
    workspacePath: "/tmp/GodotPCKStudio/session",
    extractPath: "/tmp/GodotPCKStudio/session/contents",
  });

  assert.match(session.id, /^pck-/);
  assert.equal(session.title, "game.pck");
  assert.equal(session.target.absolutePath, "/Games/Game.app/Contents/Resources/game.pck");
  assert.equal(session.workspacePath, "/tmp/GodotPCKStudio/session");
  assert.equal(session.extractPath, "/tmp/GodotPCKStudio/session/contents");
  assert.deepEqual(
    session.contentEntries.map((entry) => entry.path),
    ["project.godot", "locale/ru.po"],
  );
});

test("createStageOperation maps a dropped source file to a concrete pck target", () => {
  const operation = createStageOperation(
    { path: "/Users/me/rus/locale/ru.po", name: "ru.po", size: 512 },
    "res://locale",
  );

  assert.match(operation.id, /^op-/);
  assert.equal(operation.sourcePath, "/Users/me/rus/locale/ru.po");
  assert.equal(operation.targetPath, "locale/ru.po");
  assert.equal(operation.displayTarget, "locale/ru.po");
});

test("createStageOperation maps a dropped source file to the pck root", () => {
  const operation = createStageOperation(
    { path: "/Users/me/rus/project.godot", name: "project.godot", size: 128 },
    "",
  );

  assert.equal(operation.targetPath, "project.godot");
  assert.equal(operation.displayTarget, "project.godot");
});

test("createStageOperationAtPath stages a file at an explicit package path", () => {
  const operation = createStageOperationAtPath(
    {
      path: "translation/assets/menu.png",
      absolutePath: "/Users/me/rus/translation/assets/menu.png",
      name: "menu.png",
      size: 900,
    },
    "locale/ru/assets/menu.png",
  );

  assert.equal(operation.sourcePath, "/Users/me/rus/translation/assets/menu.png");
  assert.equal(operation.sourceDisplayPath, "translation/assets/menu.png");
  assert.equal(operation.targetPath, "locale/ru/assets/menu.png");
});

test("createStageOperation keeps native absolute paths for staged files", () => {
  const operation = createStageOperation(
    {
      path: "locale/ru.po",
      absolutePath: "/Users/me/rus/locale/ru.po",
      name: "ru.po",
      size: 512,
    },
    "res://locale",
  );

  assert.equal(operation.sourcePath, "/Users/me/rus/locale/ru.po");
  assert.equal(operation.sourceDisplayPath, "locale/ru.po");
  assert.equal(operation.targetPath, "locale/ru.po");
});

test("native file drops route to the active screen workflow", () => {
  assert.equal(nativeDropActionForMode("browser"), "open-game");
  assert.equal(nativeDropActionForMode("editor"), "add-source");
  assert.equal(nativeDropActionForMode("unknown"), null);
});

test("source drag payload must point at an existing source file", () => {
  assert.equal(sourceTransferIndex("0", 2), 0);
  assert.equal(sourceTransferIndex("1", 2), 1);
  assert.equal(sourceTransferIndex("", 2), null);
  assert.equal(sourceTransferIndex("-1", 2), null);
  assert.equal(sourceTransferIndex("2", 2), null);
  assert.equal(sourceTransferIndex("not-a-number", 2), null);
});

test("source selection follows Finder-style click shortcuts", () => {
  assert.deepEqual(sourceSelectionAfterClick([], "a.txt", { toggle: false }), ["a.txt"]);
  assert.deepEqual(sourceSelectionAfterClick(["a.txt"], "b.txt", { toggle: true }), [
    "a.txt",
    "b.txt",
  ]);
  assert.deepEqual(sourceSelectionAfterClick(["a.txt", "b.txt"], "a.txt", { toggle: true }), [
    "b.txt",
  ]);
  assert.deepEqual(sourceSelectionAfterClick(["a.txt", "b.txt"], "c.txt", { toggle: false }), [
    "c.txt",
  ]);
});

test("cmd+a selects every visible source object", () => {
  assert.deepEqual(
    sourceSelectionAfterSelectAll([
      { path: "translation" },
      { path: "translation/locale/ru.po" },
      { path: "translation/assets/menu.png" },
    ]),
    ["translation", "translation/locale/ru.po", "translation/assets/menu.png"],
  );
});

test("dragging a selected source object moves the whole selected group", () => {
  assert.deepEqual(sourceSelectionForDrag(["a.txt", "b.txt"], "a.txt"), ["a.txt", "b.txt"]);
  assert.deepEqual(sourceSelectionForDrag(["a.txt", "b.txt"], "c.txt"), ["c.txt"]);
});

test("selected folders preserve their folder names when staged with byte totals", () => {
  const operations = stageOperationsForSourcePaths(
    [
      {
        path: "translation/assets/menu.png",
        absolutePath: "/mods/translation/assets/menu.png",
        name: "menu.png",
        size: 900,
      },
      {
        path: "translation/UI/main.tscn",
        absolutePath: "/mods/translation/UI/main.tscn",
        name: "main.tscn",
        size: 300,
      },
    ],
    ["translation/assets", "translation/UI/main.tscn"],
    "res://",
  );

  assert.deepEqual(
    operations.map((operation) => [operation.targetPath, operation.size]),
    [
      ["assets/menu.png", 900],
      ["main.tscn", 300],
    ],
  );
  assert.equal(summarizeOperations(operations).bytes, 1200);
});

test("drag preview describes a visible stack for multi-item drags", () => {
  assert.deepEqual(describeDragStack(["translation/assets", "translation/UI"]), {
    count: 2,
    label: "2 items",
    names: ["assets", "UI"],
  });
  assert.deepEqual(describeDragStack(["translation/assets/menu.png"]), {
    count: 1,
    label: "menu.png",
    names: ["menu.png"],
  });
});

test("normalizePckTarget keeps targets safe and relative", () => {
  assert.equal(normalizePckTarget("res://locale//ru.po"), "locale/ru.po");
  assert.equal(normalizePckTarget("/locale/ru.po"), "locale/ru.po");
  assert.equal(normalizePckTarget("../locale/ru.po"), "locale/ru.po");
});

test("summarizeOperations returns count and total bytes", () => {
  const summary = summarizeOperations([
    createStageOperation({ path: "/a.txt", name: "a.txt", size: 4 }, "res://"),
    createStageOperation({ path: "/b.txt", name: "b.txt", size: 6 }, "res://"),
  ]);

  assert.deepEqual(summary, {
    count: 2,
    bytes: 10,
    targets: ["a.txt", "b.txt"],
  });
});

test("stage operations show whether they add or replace pck files", () => {
  const operations = [
    createStageOperation({ path: "/mods/ru.po", name: "ru.po", size: 512 }, "locale"),
    createStageOperation({ path: "/mods/new.csv", name: "new.csv", size: 64 }, "locale"),
  ];

  const marked = markStageOperationActions(operations, [{ path: "locale/ru.po", size: 12 }]);

  assert.deepEqual(
    marked.map((operation) => [operation.targetPath, operation.action]),
    [
      ["locale/ru.po", "replace"],
      ["locale/new.csv", "add"],
    ],
  );
});

test("pack progress describes visible copy and replace work", () => {
  const operations = [
    { action: "add", size: 64 },
    { action: "replace", size: 128 },
    { action: "replace", size: 256 },
  ];

  assert.deepEqual(describePackProgress("writing", operations, true), {
    phase: "writing",
    labelKey: "packWriting",
    percent: 58,
    addCount: 1,
    replaceCount: 2,
    backup: true,
    bytes: 448,
  });
});

test("successful repack folds staged files into the visible pck content", () => {
  const operations = [
    createStageOperation(
      { path: "/mods/ru.po", name: "ru.po", size: 512 },
      "locale",
    ),
    createStageOperation(
      { path: "/mods/project.godot", name: "project.godot", size: 64 },
      "",
    ),
  ];

  const merged = mergeContentEntriesWithOperations(
    [
      { path: "locale/en.po", name: "en.po", size: 256 },
      { path: "locale/ru.po", name: "ru.po", size: 12 },
    ],
    operations,
  );

  assert.deepEqual(
    merged.map((entry) => [entry.path, entry.name, entry.size, entry.kind]),
    [
      ["locale/en.po", "en.po", 256, "file"],
      ["locale/ru.po", "ru.po", 512, "file"],
      ["project.godot", "project.godot", 64, "file"],
    ],
  );
});

test("the main editor UI does not expose the removed command export dialog", () => {
  const html = readFileSync(new URL("../src/index.html", import.meta.url), "utf8");

  assert.equal(html.includes('id="save-state"'), false);
  assert.equal(html.includes('id="export-command"'), false);
  assert.equal(html.includes('id="export-dialog"'), false);
  assert.equal(html.includes('id="download-export"'), false);
});

test("the desktop game picker uses a Rust command instead of the JS dialog plugin", () => {
  const app = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");

  assert.match(app, /invoke\("open_game_path_dialog"\)/);
  assert.doesNotMatch(app, /pickNativeGamePaths/);
});

test("editor native drops and pck root drops are explicit workflows", () => {
  const app = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");

  assert.match(app, /nativeDropActionForMode\(state\.mode\)/);
  assert.match(app, /loadSource\(entries\)/);
  assert.match(app, /wirePckPaneDropTarget\(elements\.pckContentTree/);
  assert.match(app, /sourceTransferIndex\(/);
});

test("editor exposes classic file controls for selection, backup, and progress", () => {
  const html = readFileSync(new URL("../src/index.html", import.meta.url), "utf8");
  const app = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");

  assert.match(html, /vendor\/quasar\.prod\.css/);
  assert.match(html, /vendor\/vue\.global\.prod\.js/);
  assert.match(html, /vendor\/quasar\.umd\.prod\.js/);
  assert.match(html, /quasar-progress\.js/);
  assert.match(html, /id="backup-original"/);
  assert.match(html, /id="pack-progress"/);
  assert.match(html, /id="pack-dialog"/);
  assert.match(html, /id="pack-dialog-bar"/);
  assert.match(html, /id="pack-dialog-replace-count"/);
  assert.match(html, /id="repack-label"/);
  assert.match(app, /sourceSelectionAfterClick/);
  assert.match(app, /sourceSelectionAfterSelectAll/);
  assert.match(app, /backupOriginal/);
  assert.match(app, /setPackProgress/);
  assert.match(app, /describePackProgress/);
  assert.match(app, /createDragPreview/);
  assert.match(app, /setDragImage/);
  assert.match(app, /pack-progress-change/);
  assert.match(app, /preventTextSelection/);
});

test("Quasar UMD assets are vendored for offline Tauri builds", () => {
  for (const path of [
    "../src/vendor/quasar.prod.css",
    "../src/vendor/vue.global.prod.js",
    "../src/vendor/quasar.umd.prod.js",
    "../src/quasar-progress.js",
  ]) {
    assert.equal(existsSync(new URL(path, import.meta.url)), true, path);
  }
});
