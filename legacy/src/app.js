import {
  buildTree,
  classifyGameOpen,
  createEditorSession,
  createStageOperation,
  describeDragStack,
  describePackProgress,
  detectGodotTargets,
  filterProjectEntries,
  formatBytes,
  markStageOperationActions,
  mergeContentEntriesWithOperations,
  nativeDropActionForMode,
  normalizePckTarget,
  sourceSelectionAfterClick,
  sourceSelectionAfterSelectAll,
  sourceSelectionForDrag,
  stageOperationsForSourcePaths,
  shouldRerenderAfterPckSelect,
  sourceTransferIndex,
  summarizeOperations,
} from "./core/file-workflow.js";
import { LOCALES, normalizeLocale, translate } from "./i18n.js";

const LANGUAGE_KEY = "godot-pck-studio-language";
const SESSIONS_KEY = "godot-pck-studio-sessions";
const EDITOR_HASH = "editor";
const SOURCE_TRANSFER_INDEX = "application/x-source-index";
const SOURCE_TRANSFER_PATH = "application/x-source-path";
const SOURCE_TRANSFER_PATHS = "application/x-source-paths";
const SOURCE_TRANSFER_TEXT_PREFIX = "godot-pck-source:";

const editorSessionId = readEditorSessionId();

const state = {
  mode: editorSessionId ? "editor" : "browser",
  locale: normalizeLocale(localStorage.getItem(LANGUAGE_KEY) || navigator.language || "ru"),
  gameEntries: [],
  pckTargets: [],
  projectQuery: "",
  selectedTarget: null,
  editorSession: editorSessionId ? loadSession(editorSessionId) : null,
  sourceEntries: [],
  pckEntries: [],
  operations: [],
  contentStatus: "",
  selectedSourcePaths: [],
  packProgress: null,
};
const dragState = {
  sourceActive: false,
  suppressClicksUntil: 0,
  preview: null,
};
const openingTargets = new Set();

if (state.editorSession) {
  state.pckEntries = state.editorSession.contentEntries ?? [];
  state.operations = markStageOperationActions(state.editorSession.operations ?? [], state.pckEntries);
  state.contentStatus = state.editorSession.contentStatus ?? "";
}

const elements = {
  modeLabel: document.querySelector("#mode-label"),
  languageButton: document.querySelector("#language-button"),
  languageMenu: document.querySelector("#language-menu"),
  browserScreen: document.querySelector("#browser-screen"),
  editorScreen: document.querySelector("#editor-screen"),
  gameDrop: document.querySelector("#game-drop"),
  gameInput: document.querySelector("#game-input"),
  pickGame: document.querySelector("#pick-game"),
  projectSearch: document.querySelector("#project-search"),
  projectTree: document.querySelector("#project-tree"),
  pckList: document.querySelector("#pck-list"),
  pckCount: document.querySelector("#pck-count"),
  editorTitle: document.querySelector("#editor-title"),
  editorSubtitle: document.querySelector("#editor-subtitle"),
  sourceDrop: document.querySelector("#source-drop"),
  contentDrop: document.querySelector("#content-drop"),
  sourceInput: document.querySelector("#source-input"),
  pickSource: document.querySelector("#pick-source"),
  sourceTree: document.querySelector("#source-tree"),
  pckContentTree: document.querySelector("#pck-content-tree"),
  contentCount: document.querySelector("#content-count"),
  contentStatus: document.querySelector("#content-status"),
  stageList: document.querySelector("#stage-list"),
  stageSize: document.querySelector("#stage-size"),
  targetName: document.querySelector("#target-name"),
  clearStage: document.querySelector("#clear-stage"),
  repackTarget: document.querySelector("#repack-target"),
  backupOriginal: document.querySelector("#backup-original"),
  packProgress: document.querySelector("#pack-progress"),
  packProgressLabel: document.querySelector("#pack-progress-label"),
  packProgressPercent: document.querySelector("#pack-progress-percent"),
  packProgressBar: document.querySelector("#pack-progress-bar"),
  packDialog: document.querySelector("#pack-dialog"),
  packDialogTitle: document.querySelector("#pack-dialog-title"),
  packDialogMessage: document.querySelector("#pack-dialog-message"),
  packDialogPercent: document.querySelector("#pack-dialog-percent"),
  packDialogBar: document.querySelector("#pack-dialog-bar"),
  packDialogAddCount: document.querySelector("#pack-dialog-add-count"),
  packDialogReplaceCount: document.querySelector("#pack-dialog-replace-count"),
  packDialogSize: document.querySelector("#pack-dialog-size"),
  packDialogBackup: document.querySelector("#pack-dialog-backup"),
  repackLabel: document.querySelector("#repack-label"),
};

elements.pickGame.addEventListener("click", () => pickNativeOrBrowser("game"));
elements.gameInput.addEventListener("change", () => loadGame(filesFromList(elements.gameInput.files)));
elements.projectSearch.addEventListener("input", () => {
  state.projectQuery = elements.projectSearch.value;
  renderProjectTree();
});
elements.pickSource.addEventListener("click", () => pickNativeOrBrowser("source"));
elements.sourceInput.addEventListener("change", () => loadSource(filesFromList(elements.sourceInput.files)));
elements.clearStage.addEventListener("click", () => {
  state.operations = [];
  persistCurrentSession();
  renderTransferState();
});
elements.repackTarget.addEventListener("click", () => repackTarget());
elements.languageButton.addEventListener("click", () => {
  const nextHidden = !elements.languageMenu.hidden;
  elements.languageMenu.hidden = nextHidden;
  elements.languageButton.setAttribute("aria-expanded", String(!nextHidden));
});
document.addEventListener("click", (event) => {
  if (event.target.closest(".language-switcher")) {
    return;
  }
  closeLanguageMenu();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeLanguageMenu();
    return;
  }

  if (
    state.mode === "editor" &&
    (event.metaKey || event.ctrlKey) &&
    event.key.toLowerCase() === "a" &&
    !isEditableTarget(event.target)
  ) {
    event.preventDefault();
    state.selectedSourcePaths = sourceSelectionAfterSelectAll(visibleSourceNodes());
    renderSource();
  }
});
elements.languageMenu.addEventListener("click", (event) => {
  const button = event.target.closest("[data-locale]");
  if (!button) {
    return;
  }
  setLocale(button.dataset.locale);
  closeLanguageMenu();
});

wireDropZone(elements.gameDrop, async (event) => {
  await loadDroppedGame(event.dataTransfer);
});

wireDropZone(elements.sourceDrop, async (event) => {
  loadSource(await filesFromDrop(event.dataTransfer));
});

wirePckPaneDropTarget(elements.contentDrop, "");
wirePckPaneDropTarget(elements.pckContentTree, "");

applyLocale();
wireNativeFileDrops();
wireEditorWorkspaceCleanup();
render();

function setLocale(locale) {
  state.locale = normalizeLocale(locale);
  localStorage.setItem(LANGUAGE_KEY, state.locale);
  applyLocale();
  render();
}

function t(key) {
  return translate(state.locale, key);
}

function closeLanguageMenu() {
  elements.languageMenu.hidden = true;
  elements.languageButton.setAttribute("aria-expanded", "false");
}

function isEditableTarget(target) {
  return Boolean(target?.closest?.("input, textarea, select, [contenteditable='true']"));
}

function applyLocale() {
  document.documentElement.lang = state.locale === "zh" ? "zh-CN" : state.locale;
  elements.modeLabel.textContent = window.__TAURI__ ? t("appModeTauri") : t("appModeBrowser");

  for (const node of document.querySelectorAll("[data-i18n]")) {
    node.textContent = t(node.dataset.i18n);
  }

  for (const node of document.querySelectorAll("[data-i18n-title]")) {
    node.title = t(node.dataset.i18nTitle);
    node.setAttribute("aria-label", t(node.dataset.i18nTitle));
  }

  for (const node of document.querySelectorAll("[data-i18n-placeholder]")) {
    node.placeholder = t(node.dataset.i18nPlaceholder);
  }

  for (const locale of LOCALES) {
    const button = elements.languageMenu.querySelector(`[data-locale="${locale}"]`);
    button?.toggleAttribute("data-selected", locale === state.locale);
  }
}

function render() {
  elements.browserScreen.hidden = state.mode !== "browser";
  elements.editorScreen.hidden = state.mode !== "editor";

  if (state.mode === "editor") {
    renderEditor();
    return;
  }

  renderBrowser();
}

async function loadGame(entries, options = {}) {
  const result = classifyGameOpen(entries);
  if (result.kind === "direct-pck") {
    await openPck(result.targets[0]);
    return;
  }

  state.gameEntries = entries;
  state.pckTargets = result.targets;
  state.selectedTarget = result.targets[0] ?? null;
  renderBrowser();
}

async function loadDroppedGame(dataTransfer) {
  const dropped = await filesFromDrop(dataTransfer);
  await loadGame(dropped, { source: "drop" });
}

function renderBrowser() {
  renderPckList();
  renderProjectTree();
}

function renderPckList() {
  elements.pckCount.textContent = String(state.pckTargets.length);
  elements.pckList.replaceChildren();

  if (!state.pckTargets.length) {
    elements.pckList.append(emptyCopy(state.gameEntries.length ? t("pckMissing") : t("gameEmpty")));
    return;
  }

  for (const target of state.pckTargets) {
    const card = document.createElement("button");
    card.type = "button";
    card.className = "pck-card";
    card.dataset.selected = target.pckPath === state.selectedTarget?.pckPath ? "true" : "false";
    card.dataset.pckPath = target.pckPath;
    card.title = target.pckPath;
    card.addEventListener("click", () => selectTarget(target, { rerender: false }));
    card.addEventListener("dblclick", () => openPck(target));

    const badge = document.createElement("span");
    badge.className = "pck-badge";
    badge.textContent = ".pck";

    const name = document.createElement("strong");
    name.textContent = target.pckName;

    const path = document.createElement("span");
    path.textContent = target.kind === "mac-app" ? target.appName : target.appRoot;

    const open = document.createElement("span");
    open.className = "open-copy";
    open.textContent = t("openPck");

    card.append(badge, name, path, open);
    elements.pckList.append(card);
  }
}

function renderProjectTree() {
  const entries = filterProjectEntries(state.gameEntries, state.projectQuery);
  renderTree(elements.projectTree, buildTree(entries), {
    emptyMessage: state.gameEntries.length ? t("pckMissing") : t("gameEmpty"),
    openablePck: true,
    showRoot: false,
    onSelectPck: selectTarget,
    onOpenPck: openPck,
  });
}

function selectTarget(target, options = {}) {
  state.selectedTarget = target;
  if (!shouldRerenderAfterPckSelect(options)) {
    updateSelectedTargetMarkers();
    return;
  }

  renderPckList();
  renderProjectTree();
}

function updateSelectedTargetMarkers() {
  const selectedPath = state.selectedTarget?.pckPath ?? "";
  for (const node of document.querySelectorAll("[data-pck-path]")) {
    node.dataset.selected = node.dataset.pckPath === selectedPath ? "true" : "false";
  }
}

async function openPck(target) {
  if (openingTargets.has(target.absolutePath)) {
    return;
  }

  openingTargets.add(target.absolutePath);
  state.selectedTarget = target;
  updateSelectedTargetMarkers();

  try {
    const contentResult = await readPckContents(target);
    const session = createEditorSession(target, contentResult.entries, contentResult.workspace);
    session.contentStatus = contentResult.status;
    saveSession(session);
    await openEditorWindow(session);
  } finally {
    openingTargets.delete(target.absolutePath);
  }
}

async function readPckContents(target) {
  const tauri = getTauri();
  if (!tauri?.core?.invoke) {
    return { entries: [], status: t("pckListBrowser") };
  }

  try {
    const workspace = await tauri.core.invoke("open_pck_workspace", {
      pckPath: target.absolutePath,
    });
    const entries = workspace.entries ?? [];
    return {
      entries,
      workspace,
      status: entries.length ? "" : t("pckListEmpty"),
    };
  } catch (error) {
    return {
      entries: [],
      status: friendlyPckToolError(error),
    };
  }
}

async function openEditorWindow(session) {
  const tauri = getTauri();

  if (tauri?.core?.invoke) {
    try {
      await tauri.core.invoke("open_editor_window", {
        sessionId: session.id,
        title: session.title,
      });
      return;
    } catch {
      openBrowserWindow(session);
      return;
    }
  }

  if (openBrowserWindow(session)) {
    return;
  }

  enterEditorSession(session.id);
}

function openBrowserWindow(session) {
  const url = new URL(window.location.href);
  url.hash = `${EDITOR_HASH}=${encodeURIComponent(session.id)}`;
  const opened = window.open(
    url.href,
    `pck-${session.id}`,
    "popup,width=1220,height=780,menubar=no,toolbar=no",
  );
  opened?.focus();
  return Boolean(opened);
}

function enterEditorSession(sessionId) {
  const session = loadSession(sessionId);
  if (!session) {
    return;
  }

  state.mode = "editor";
  state.editorSession = session;
  state.pckEntries = session.contentEntries ?? [];
  state.operations = markStageOperationActions(session.operations ?? [], state.pckEntries);
  state.contentStatus = session.contentStatus ?? "";
  window.location.hash = `${EDITOR_HASH}=${encodeURIComponent(sessionId)}`;
  render();
}

function renderEditor() {
  if (!state.editorSession) {
    state.mode = "browser";
    render();
    return;
  }

  elements.editorTitle.textContent = state.editorSession.title;
  elements.editorSubtitle.textContent = state.editorSession.target?.pckPath ?? "";
  elements.contentCount.textContent = String(state.pckEntries.length);
  elements.contentStatus.textContent = state.contentStatus;
  elements.contentStatus.hidden = !state.contentStatus;

  renderSource();
  renderPckContent();
  renderTransferState();
}

function loadSource(entries) {
  state.sourceEntries = entries;
  state.selectedSourcePaths = [];
  renderSource();
}

function renderSource() {
  elements.sourceDrop.classList.toggle("has-files", state.sourceEntries.length > 0);
  renderTree(elements.sourceTree, buildTree(state.sourceEntries), {
    draggableFiles: true,
    emptyMessage: t("filesDrop"),
    showRoot: false,
  });
}

function visibleSourceNodes() {
  const tree = buildTree(state.sourceEntries);
  const nodes = [];
  const visit = (node) => {
    for (const child of node.children ?? []) {
      nodes.push({ path: child.path });
      if (child.children?.length) {
        visit(child);
      }
    }
  };
  visit(tree);
  return nodes;
}

function renderPckContent() {
  const mergedEntries = [
    ...state.pckEntries,
    ...state.operations.map((operation) => ({
      path: operation.targetPath,
      size: operation.size,
      staged: true,
    })),
  ];

  renderTree(elements.pckContentTree, buildTree(mergedEntries), {
    droppableDirectories: true,
    emptyMessage: t("pckContentEmpty"),
    showRoot: true,
  });
}

function addOperation(sourceIndex, targetDirectory) {
  const source = state.sourceEntries[sourceIndex];
  if (!state.editorSession || !source || source.kind === "directory") {
    return;
  }

  addStageOperations([createStageOperation(source, targetDirectory)]);
}

function addStageOperations(operations) {
  if (!operations.length) {
    return;
  }

  const markedOperations = uniqueOperationsById(markStageOperationActions(operations, state.pckEntries));
  const ids = new Set(markedOperations.map((operation) => operation.id));
  state.operations = [
    ...state.operations.filter((existing) => !ids.has(existing.id)),
    ...markedOperations,
  ];
  persistCurrentSession();
  renderTransferState();
}

function uniqueOperationsById(operations) {
  return [...new Map(operations.map((operation) => [operation.id, operation])).values()];
}

function removeOperation(operationId) {
  state.operations = state.operations.filter((operation) => operation.id !== operationId);
  persistCurrentSession();
  renderTransferState();
}

function renderTransferState() {
  const summary = summarizeOperations(state.operations);
  elements.stageSize.textContent = formatBytes(summary.bytes);
  elements.targetName.textContent = state.editorSession?.target?.pckName ?? t("pckMissing");
  elements.repackTarget.disabled =
    !state.editorSession?.target || state.operations.length === 0 || Boolean(state.packProgress);

  renderPckContent();
  renderChanges();
  renderPackProgress();
}

function renderChanges() {
  elements.stageList.replaceChildren();

  if (!state.operations.length) {
    elements.stageList.append(emptyCopy(t("changesEmpty")));
    return;
  }

  for (const operation of state.operations) {
    const item = document.createElement("article");
    item.className = "change-item";

    const route = document.createElement("div");
    route.className = "change-route";

    const source = document.createElement("strong");
    source.textContent = operation.sourceDisplayPath || operation.sourceName;

    const target = document.createElement("span");
    target.textContent = operation.displayTarget;

    const action = document.createElement("span");
    action.className = `action-badge ${operation.action === "replace" ? "replace" : "add"}`;
    action.textContent = operation.action === "replace" ? t("replaceAction") : t("addAction");

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove-button";
    remove.textContent = "x";
    remove.addEventListener("click", () => removeOperation(operation.id));

    const size = document.createElement("small");
    size.textContent = formatBytes(operation.size);

    route.append(source, target);
    item.append(action, route, size, remove);
    elements.stageList.append(item);
  }
}

function renderTree(container, tree, options) {
  container.replaceChildren();

  if (!tree.children?.length && !options.showRoot) {
    container.append(emptyCopy(options.emptyMessage));
    return;
  }

  const list = document.createElement("ul");
  list.className = "tree-list";

  if (options.showRoot) {
    list.append(renderTreeItem(tree, options, true, 0));
  } else {
    for (const child of tree.children) {
      list.append(renderTreeItem(child, options, false, 0));
    }
  }

  container.append(list);
}

function renderTreeItem(node, options, isRoot, depth) {
  const item = document.createElement("li");
  item.className = "tree-item";

  if (node.kind === "directory") {
    const details = document.createElement("details");
    details.open = isRoot || depth < 1;

    const row = document.createElement("summary");
    row.className = "file-row directory";
    row.title = node.path || t("packageRoot");
    row.style.setProperty("--depth", String(depth));
    preventTextSelection(row);
    wireSourceSelection(row, node, options);
    wireDirectoryDrop(row, node, options);
    wireSourceDrag(row, node, options);
    row.append(...treeRowParts(node, isRoot, false));

    details.append(row);
    if (node.children?.length) {
      const list = document.createElement("ul");
      list.className = "tree-list";
      for (const child of node.children) {
        list.append(renderTreeItem(child, options, false, depth + 1));
      }
      details.append(list);
    }

    item.append(details);
    return item;
  }

  const pckTarget = options.openablePck ? targetForPath(node.path) : null;
  const row = document.createElement("div");
  row.className = `file-row file ${fileTone(node.name)}${pckTarget ? " pck-row" : ""}`;
  row.title = node.path;
  row.style.setProperty("--depth", String(depth));
  preventTextSelection(row);
  wireSourceSelection(row, node, options);

  if (pckTarget) {
    row.dataset.selected = pckTarget.pckPath === state.selectedTarget?.pckPath ? "true" : "false";
    row.dataset.pckPath = pckTarget.pckPath;
    row.addEventListener("click", (event) => {
      event.stopPropagation();
      options.onSelectPck?.(pckTarget, { rerender: false });
    });
    row.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
      options.onOpenPck?.(pckTarget);
    });
  }

  wireSourceDrag(row, node, options);

  row.append(...treeRowParts(node, false, Boolean(pckTarget)));

  if (pckTarget) {
    const open = document.createElement("button");
    open.type = "button";
    open.className = "inline-open";
    open.textContent = t("openPck");
    open.addEventListener("click", (event) => {
      event.stopPropagation();
      options.onOpenPck?.(pckTarget);
    });
    row.append(open);
  }

  item.append(row);
  return item;
}

function treeRowParts(node, isRoot, isPck) {
  const glyph = document.createElement("span");
  glyph.className = "glyph";
  glyph.innerHTML = iconSvg(node.kind === "directory" ? "folder" : iconType(node.name));

  const name = document.createElement("span");
  name.className = "file-name";
  name.textContent = isRoot ? t("packageRoot") : node.name;

  const meta = document.createElement("span");
  meta.className = "file-meta";
  meta.textContent = isPck ? t("pckOpenHint") : node.kind === "file" ? formatBytes(node.size) : "";

  return [glyph, name, meta];
}

function preventTextSelection(row) {
  row.addEventListener("mousedown", (event) => {
    if (event.detail > 1 || event.metaKey || event.ctrlKey) {
      event.preventDefault();
    }
  });
  row.addEventListener("dblclick", (event) => {
    event.preventDefault();
  });
}

function wireSourceSelection(row, node, options) {
  if (!options.draggableFiles) {
    return;
  }

  const sourcePath = normalizePckTarget(node.path);
  row.dataset.sourcePath = sourcePath;
  row.dataset.sourceSelected = state.selectedSourcePaths.includes(sourcePath) ? "true" : "false";

  row.addEventListener("click", (event) => {
    if (shouldSuppressTreeClick()) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    const toggle = event.metaKey || event.ctrlKey;
    if (node.kind === "directory" && !toggle) {
      return;
    }

    state.selectedSourcePaths = sourceSelectionAfterClick(state.selectedSourcePaths, sourcePath, {
      toggle,
    });
    renderSource();

    if (toggle) {
      event.preventDefault();
    }
  });
}

function wireSourceDrag(row, node, options) {
  if (!options.draggableFiles) {
    return;
  }

  row.draggable = true;
  row.addEventListener("dragstart", (event) => {
    const index = state.sourceEntries.findIndex((entry) => entry.path === node.path);
    if (node.kind === "file" && index < 0) {
      event.preventDefault();
      return;
    }

    const dragPaths = sourceSelectionForDrag(state.selectedSourcePaths, node.path);
    dragState.sourceActive = true;
    row.classList.add("dragging");
    document.body.classList.add("source-dragging");
    event.dataTransfer.effectAllowed = "copy";
    event.dataTransfer.setData(SOURCE_TRANSFER_PATHS, JSON.stringify(dragPaths));
    event.dataTransfer.setData(SOURCE_TRANSFER_PATH, dragPaths[0] ?? node.path);
    event.dataTransfer.setData("text/plain", `${SOURCE_TRANSFER_TEXT_PREFIX}${dragPaths.join("\n")}`);
    setDragImage(event.dataTransfer, createDragPreview(dragPaths));
    if (node.kind === "file") {
      event.dataTransfer.setData(SOURCE_TRANSFER_INDEX, String(index));
    }
  });
  row.addEventListener("dragend", () => {
    row.classList.remove("dragging");
    finishSourceDrag();
  });
}

function wireDirectoryDrop(row, node, options) {
  if (!options.droppableDirectories) {
    return;
  }

  row.addEventListener("click", (event) => {
    if (!shouldSuppressTreeClick()) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
  });
  row.addEventListener("dragover", (event) => {
    event.preventDefault();
    row.classList.add("drop-ready");
    event.dataTransfer.dropEffect = "copy";
  });
  row.addEventListener("dragleave", () => row.classList.remove("drop-ready"));
  row.addEventListener("drop", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    row.classList.remove("drop-ready");
    await stageTransferToDirectory(event.dataTransfer, node.path);
  });
}

function wirePckPaneDropTarget(zone, targetDirectory) {
  wireDropZone(zone, async (event) => {
    event.stopPropagation();
    await stageTransferToDirectory(event.dataTransfer, targetDirectory);
  });
}

async function stageTransferToDirectory(dataTransfer, targetDirectory) {
  const sourcePaths = sourcePathsFromDataTransfer(dataTransfer);
  if (sourcePaths.length && addOperationsForSourcePaths(sourcePaths, targetDirectory)) {
    finishSourceDrag();
    return true;
  }

  const sourceIndex = sourceIndexFromDataTransfer(dataTransfer);
  if (sourceIndex !== null) {
    addOperation(sourceIndex, targetDirectory);
    finishSourceDrag();
    return true;
  }

  const dropped = await filesFromDrop(dataTransfer);
  if (!dropped.length) {
    finishSourceDrag();
    return false;
  }

  const startIndex = state.sourceEntries.length;
  state.sourceEntries = [...state.sourceEntries, ...dropped];
  const operations = dropped
    .map((entry, offset) =>
      createStageOperation(state.sourceEntries[startIndex + offset], targetDirectory),
    )
    .filter(Boolean);
  addStageOperations(operations);
  renderSource();
  finishSourceDrag();
  return true;
}

function sourceIndexFromDataTransfer(dataTransfer) {
  return sourceTransferIndex(
    dataTransfer?.getData(SOURCE_TRANSFER_INDEX),
    state.sourceEntries.length,
  );
}

function sourcePathsFromDataTransfer(dataTransfer) {
  const json = dataTransfer?.getData(SOURCE_TRANSFER_PATHS);
  if (json) {
    try {
      const paths = JSON.parse(json);
      if (Array.isArray(paths)) {
        return paths.map(normalizePckTarget).filter(Boolean);
      }
    } catch {
      return [];
    }
  }

  const direct = dataTransfer?.getData(SOURCE_TRANSFER_PATH);
  if (direct) {
    return [normalizePckTarget(direct)].filter(Boolean);
  }

  const text = dataTransfer?.getData("text/plain") ?? "";
  if (!text.startsWith(SOURCE_TRANSFER_TEXT_PREFIX)) {
    return [];
  }

  return text
    .slice(SOURCE_TRANSFER_TEXT_PREFIX.length)
    .split("\n")
    .map(normalizePckTarget)
    .filter(Boolean);
}

function addOperationsForSourcePaths(sourcePaths, targetDirectory) {
  const operations = stageOperationsForSourcePaths(state.sourceEntries, sourcePaths, targetDirectory);

  addStageOperations(operations);
  return operations.length > 0;
}

function createDragPreview(paths) {
  const stack = describeDragStack(paths);
  const preview = document.createElement("div");
  preview.className = "drag-preview";

  const stackIcon = document.createElement("span");
  stackIcon.className = "drag-preview-stack";
  for (let index = 0; index < Math.min(3, Math.max(1, stack.count)); index += 1) {
    stackIcon.append(document.createElement("i"));
  }

  const count = document.createElement("strong");
  count.textContent = String(stack.count);

  const label = document.createElement("span");
  label.textContent = stack.label;

  preview.append(stackIcon, count, label);
  document.body.append(preview);
  dragState.preview = preview;
  return preview;
}

function setDragImage(dataTransfer, preview) {
  if (!dataTransfer?.setDragImage || !preview) {
    return;
  }
  dataTransfer.setDragImage(preview, 18, 18);
}

function finishSourceDrag() {
  if (!dragState.sourceActive) {
    return;
  }

  dragState.sourceActive = false;
  dragState.suppressClicksUntil = Date.now() + 250;
  dragState.preview?.remove();
  dragState.preview = null;
  document.body.classList.remove("source-dragging");
}

function shouldSuppressTreeClick() {
  return dragState.sourceActive || Date.now() < dragState.suppressClicksUntil;
}

function targetForPath(path) {
  return state.pckTargets.find((target) => target.pckPath === path) ?? null;
}

function toRepackOperations(operations) {
  return operations.map((operation) => ({
    file: operation.sourcePath,
    target: operation.targetPath,
  }));
}

async function repackTarget() {
  const tauri = getTauri();
  if (!state.editorSession?.target || state.operations.length === 0 || state.packProgress) {
    return;
  }

  if (!tauri?.core?.invoke) {
    state.contentStatus = t("pckListBrowser");
    persistCurrentSession();
    renderEditor();
    return;
  }

  try {
    const packedOperations = state.operations;
    const backupOriginal = elements.backupOriginal.checked;
    setPackProgress("preparing", packedOperations, backupOriginal);
    await nextFrame();
    if (backupOriginal) {
      setPackProgress("backup", packedOperations, backupOriginal);
      await wait(160);
    }
    setPackProgress("writing", packedOperations, backupOriginal);
    const result = await tauri.core.invoke("repack_pck", {
      pckPath: state.editorSession.target.absolutePath,
      operations: toRepackOperations(packedOperations),
      workspacePath: state.editorSession.workspacePath || null,
      backupOriginal,
    });

    state.pckEntries = mergeContentEntriesWithOperations(state.pckEntries, packedOperations);
    state.operations = [];
    state.editorSession.workspacePath = "";
    state.editorSession.extractPath = "";
    state.contentStatus = result;
    setPackProgress("done", packedOperations, backupOriginal);
    persistCurrentSession();
    renderEditor();
    setTimeout(() => {
      if (state.packProgress?.phase === "done") {
        state.packProgress = null;
        renderTransferState();
      }
    }, 1200);
  } catch (error) {
    state.contentStatus = friendlyPckToolError(error);
    setPackProgress("failed", state.operations, elements.backupOriginal.checked);
    persistCurrentSession();
    renderEditor();
    setTimeout(() => {
      if (state.packProgress?.phase === "failed") {
        state.packProgress = null;
        renderTransferState();
      }
    }, 1800);
  }
}

function setPackProgress(phase, operations = state.operations, backup = elements.backupOriginal.checked) {
  state.packProgress = describePackProgress(phase, operations, backup);
  renderPackProgress();
  renderTransferStateButton();
}

function renderTransferStateButton() {
  elements.repackTarget.disabled =
    !state.editorSession?.target || state.operations.length === 0 || Boolean(state.packProgress);
}

function renderPackProgress() {
  const quasarProgress = isQuasarProgressAvailable();
  if (!state.packProgress) {
    elements.packProgress.hidden = true;
    elements.packProgressBar.value = 0;
    elements.packProgressPercent.textContent = "0%";
    elements.packProgressLabel.textContent = t("packIdle");
    elements.packDialog.hidden = true;
    elements.packDialogBar.value = 0;
    elements.packDialogPercent.textContent = "0%";
    elements.packDialogAddCount.textContent = "0";
    elements.packDialogReplaceCount.textContent = "0";
    elements.packDialogSize.textContent = "0 B";
    elements.packDialogBackup.textContent = "";
    elements.repackLabel.textContent = t("repack");
    emitPackProgress(null);
    return;
  }

  const percent = Math.max(0, Math.min(100, Number(state.packProgress.percent ?? 0)));
  elements.packProgress.hidden = false;
  elements.packProgressBar.value = percent;
  elements.packProgressPercent.textContent = `${percent}%`;
  elements.packProgressLabel.textContent = t(state.packProgress.labelKey);
  elements.packDialog.hidden = quasarProgress;
  elements.packDialogBar.value = percent;
  elements.packDialogPercent.textContent = `${percent}%`;
  elements.packDialogTitle.textContent = t(state.packProgress.labelKey);
  elements.packDialogMessage.textContent = t("packDialogMessage");
  elements.packDialogAddCount.textContent = String(state.packProgress.addCount);
  elements.packDialogReplaceCount.textContent = String(state.packProgress.replaceCount);
  elements.packDialogSize.textContent = formatBytes(state.packProgress.bytes);
  elements.packDialogBackup.textContent = state.packProgress.backup
    ? t("packBackupEnabled")
    : t("packBackupDisabled");
  elements.repackLabel.textContent =
    state.packProgress.phase === "done" ? t("packDone") : t("packButtonBusy");
  emitPackProgress(packProgressDetail(percent));
}

function packProgressDetail(percent) {
  return {
    ...state.packProgress,
    percent,
    kicker: t("packDialogKicker"),
    title: t(state.packProgress.labelKey),
    message: t("packDialogMessage"),
    addLabel: t("addAction"),
    replaceLabel: t("replaceAction"),
    totalLabel: t("packOperations"),
    sizeLabel: formatBytes(state.packProgress.bytes),
    backupLabel: state.packProgress.backup ? t("packBackupEnabled") : t("packBackupDisabled"),
  };
}

function emitPackProgress(detail) {
  window.dispatchEvent(new CustomEvent("pack-progress-change", { detail }));
}

function isQuasarProgressAvailable() {
  return Boolean(window.Vue && window.Quasar);
}

function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function pickNativeOrBrowser(kind) {
  const tauri = getTauri();
  const input = kind === "game" ? elements.gameInput : elements.sourceInput;

  if (!tauri?.core?.invoke || (kind !== "game" && !tauri?.dialog?.open)) {
    input.click();
    return;
  }

  const paths =
    kind === "game"
      ? normalizeDialogSelection(await tauri.core.invoke("open_game_path_dialog"))
      : normalizeDialogSelection(
          await tauri.dialog.open({
            directory: true,
            multiple: true,
          }),
        );
  if (!paths.length) {
    return;
  }

  const entries = await tauri.core.invoke("scan_paths", { paths });
  if (kind === "game") {
    await loadGame(entries);
  } else {
    loadSource(entries);
  }
}

async function wireNativeFileDrops() {
  const tauri = getTauri();
  const currentWebview = tauri?.webview?.getCurrentWebview?.();
  const currentWindow = tauri?.window?.getCurrentWindow?.();
  const dropTarget = currentWebview ?? currentWindow;

  if (!dropTarget?.onDragDropEvent || !tauri?.core?.invoke) {
    return;
  }

  await dropTarget.onDragDropEvent(async (event) => {
    const payload = event.payload;
    if (payload.type !== "drop" || !payload.paths?.length) {
      return;
    }

    const entries = await tauri.core.invoke("scan_paths", { paths: payload.paths });
    const action = nativeDropActionForMode(state.mode);
    if (action === "open-game") {
      await loadGame(entries, { source: "native-drop" });
      return;
    }
    if (action === "add-source") {
      loadSource(entries);
    }
  });
}

async function wireEditorWorkspaceCleanup() {
  if (state.mode !== "editor") {
    return;
  }

  const tauri = getTauri();
  const currentWindow = tauri?.window?.getCurrentWindow?.();
  if (!currentWindow?.onCloseRequested || !tauri?.core?.invoke) {
    return;
  }

  await currentWindow.onCloseRequested(async (event) => {
    if (!state.editorSession?.workspacePath) {
      return;
    }

    event.preventDefault();
    await cleanupCurrentWorkspace();
    await currentWindow.destroy();
  });
}

async function cleanupCurrentWorkspace() {
  const tauri = getTauri();
  const workspacePath = state.editorSession?.workspacePath;
  if (!workspacePath || !tauri?.core?.invoke) {
    return;
  }

  try {
    await tauri.core.invoke("cleanup_pck_workspace", { workspacePath });
    state.editorSession.workspacePath = "";
    state.editorSession.extractPath = "";
    persistCurrentSession();
  } catch {
    // A stale temp workspace should not block closing the editor window.
  }
}

function getTauri() {
  return window.__TAURI__;
}

function normalizeDialogSelection(selected) {
  if (Array.isArray(selected)) {
    return selected;
  }
  return selected ? [selected] : [];
}

function wireDropZone(zone, onDrop) {
  let dragDepth = 0;

  zone.addEventListener("dragenter", (event) => {
    event.preventDefault();
    dragDepth += 1;
    zone.classList.add("drop-active");
  });

  zone.addEventListener("dragover", (event) => {
    event.preventDefault();
    zone.classList.add("drop-active");
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "copy";
    }
  });

  zone.addEventListener("dragleave", () => {
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) {
      zone.classList.remove("drop-active");
    }
  });

  zone.addEventListener("drop", async (event) => {
    event.preventDefault();
    dragDepth = 0;
    zone.classList.remove("drop-active");
    await onDrop(event);
    finishSourceDrag();
  });
}

function filesFromList(fileList) {
  return Array.from(fileList ?? []).map((file) => ({
    name: file.name,
    path: file.webkitRelativePath || file.name,
    size: file.size,
    kind: "file",
    file,
  }));
}

async function filesFromDrop(dataTransfer) {
  const items = Array.from(dataTransfer?.items ?? []);
  const entries = [];

  if (items.some((item) => item.webkitGetAsEntry)) {
    for (const item of items) {
      const entry = item.webkitGetAsEntry?.();
      if (entry) {
        entries.push(...(await readEntry(entry)));
      }
    }
    return entries;
  }

  return filesFromList(dataTransfer?.files);
}

async function readEntry(entry, prefix = "") {
  if (entry.isFile) {
    const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
    return [
      {
        name: file.name,
        path: `${prefix}${file.name}`,
        size: file.size,
        kind: "file",
        file,
      },
    ];
  }

  if (!entry.isDirectory) {
    return [];
  }

  const reader = entry.createReader();
  const children = [];
  let batch = [];

  do {
    batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
    children.push(...batch);
  } while (batch.length);

  const nested = await Promise.all(
    children.map((child) => readEntry(child, `${prefix}${entry.name}/`)),
  );
  return nested.flat();
}

function persistCurrentSession() {
  if (!state.editorSession) {
    return;
  }

  state.editorSession = {
    ...state.editorSession,
    contentEntries: state.pckEntries,
    operations: state.operations,
    contentStatus: state.contentStatus,
  };
  saveSession(state.editorSession);
}

function readSessions() {
  try {
    return JSON.parse(localStorage.getItem(SESSIONS_KEY) || "{}");
  } catch {
    return {};
  }
}

function saveSession(session) {
  const sessions = readSessions();
  sessions[session.id] = session;
  localStorage.setItem(SESSIONS_KEY, JSON.stringify(sessions));
}

function loadSession(sessionId) {
  return readSessions()[sessionId] ?? null;
}

function readEditorSessionId() {
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  return params.get(EDITOR_HASH);
}

function emptyCopy(text) {
  const node = document.createElement("div");
  node.className = "empty-copy";
  node.textContent = text;
  return node;
}

function iconType(name) {
  const lower = String(name).toLowerCase();
  if (lower.endsWith(".pck")) {
    return "package";
  }
  if (lower.endsWith(".po") || lower.endsWith(".csv") || lower.endsWith(".json")) {
    return "data";
  }
  if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".webp")) {
    return "image";
  }
  if (lower.endsWith(".gd") || lower.endsWith(".tscn") || lower.endsWith(".tres")) {
    return "code";
  }
  return "file";
}

function iconSvg(type) {
  const icons = {
    folder:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6.5A2.5 2.5 0 0 1 5.5 4H10l2 2h6.5A2.5 2.5 0 0 1 21 8.5v8A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z"/></svg>',
    package:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12 4.4 7.8"/><path d="m12 12 7.6-4.2"/><path d="M12 12v8.5"/></svg>',
    image:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8.5" cy="10" r="1.5"/><path d="m21 15-4.5-4.5L8 19"/></svg>',
    data:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 4H6a2 2 0 0 0-2 2v2"/><path d="M16 4h2a2 2 0 0 1 2 2v2"/><path d="M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M16 20h2a2 2 0 0 0 2-2v-2"/><path d="m9 9-2 3 2 3"/><path d="m15 9 2 3-2 3"/></svg>',
    code:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18-6-6 6-6"/><path d="m15 6 6 6-6 6"/></svg>',
    file:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>',
  };
  return icons[type] ?? icons.file;
}

function friendlyPckToolError(_error) {
  return t("pckListFailed");
}

function fileTone(name) {
  const lower = String(name).toLowerCase();
  if (lower.endsWith(".pck")) {
    return "tone-pck";
  }
  if (lower.endsWith(".po") || lower.endsWith(".csv") || lower.endsWith(".json")) {
    return "tone-data";
  }
  if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".webp")) {
    return "tone-image";
  }
  return "tone-file";
}
