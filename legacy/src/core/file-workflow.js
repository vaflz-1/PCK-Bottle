const ROOT_NODE = {
  name: "Package root",
  path: "",
  kind: "directory",
  size: 0,
  children: [],
};

export function normalizePckTarget(value) {
  return String(value ?? "")
    .replace(/\\/g, "/")
    .replace(/^res:\/\//, "")
    .replace(/^\/+/, "")
    .split("/")
    .filter((part) => part && part !== "." && part !== "..")
    .join("/");
}

export function buildTree(entries) {
  const root = cloneNode(ROOT_NODE);

  for (const entry of entries) {
    const normalized = normalizePckTarget(entry.path);
    if (!normalized) {
      continue;
    }

    const parts = normalized.split("/");
    let cursor = root;

    parts.forEach((part, index) => {
      const isFile = index === parts.length - 1;
      const nextPath = parts.slice(0, index + 1).join("/");
      let child = cursor.children.find((node) => node.name === part);

      if (!child) {
        child = {
          name: part,
          path: nextPath,
          kind: isFile ? "file" : "directory",
          size: isFile ? Number(entry.size ?? 0) : 0,
          children: isFile ? undefined : [],
        };
        cursor.children.push(child);
      }

      if (!isFile) {
        cursor = child;
      }
    });
  }

  sortTree(root);
  return root;
}

export function detectGodotTargets(entries) {
  const targets = [];
  const seen = new Set();

  for (const entry of entries) {
    const path = String(entry.path ?? "").replace(/\\/g, "/");
    if (!path.toLowerCase().endsWith(".pck")) {
      continue;
    }

    const appMatch = path.match(/^(.+?\.app)\/Contents\/Resources\/(.+?\.pck)$/i);
    const target = appMatch
      ? {
          kind: "mac-app",
          appName: appMatch[1].split("/").at(-1),
          appRoot: appMatch[1],
          pckPath: path,
          absolutePath: String(entry.absolutePath ?? path),
          pckName: appMatch[2].split("/").at(-1),
          size: Number(entry.size ?? 0),
        }
      : {
          kind: "folder",
          appName: "Loose folder",
          appRoot: path.split("/").slice(0, -1).join("/") || ".",
          pckPath: path,
          absolutePath: String(entry.absolutePath ?? path),
          pckName: path.split("/").at(-1),
          size: Number(entry.size ?? 0),
        };

    if (!seen.has(target.pckPath)) {
      targets.push(target);
      seen.add(target.pckPath);
    }
  }

  return targets.sort((a, b) => {
    if (a.kind !== b.kind) {
      return a.kind === "mac-app" ? -1 : 1;
    }
    return a.pckPath.localeCompare(b.pckPath);
  });
}

export function classifyGameOpen(entries) {
  const targets = detectGodotTargets(entries);
  const isDirectPck =
    entries.length === 1 &&
    String(entries[0]?.path ?? entries[0]?.name ?? "")
      .toLowerCase()
      .endsWith(".pck") &&
    !String(entries[0]?.path ?? "").toLowerCase().includes(".app/") &&
    targets.length === 1;

  return {
    kind: isDirectPck ? "direct-pck" : targets.length ? "game-browser" : "empty",
    targets,
  };
}

export function filterProjectEntries(entries, query = "") {
  const normalizedQuery = String(query ?? "").trim().toLowerCase();
  if (!normalizedQuery) {
    return [...entries];
  }

  return entries.filter((entry) =>
    String(entry.path ?? entry.name ?? "").toLowerCase().includes(normalizedQuery),
  );
}

export function shouldRerenderAfterPckSelect(options = {}) {
  return options?.rerender !== false;
}

export function createEditorSession(target, contentEntries = [], workspace = {}) {
  const pckPath = String(target?.absolutePath ?? target?.pckPath ?? "");
  const title = String(target?.pckName ?? pckPath.split(/[\\/]/).at(-1) ?? "PCK");

  return {
    id: `pck-${hashParts(pckPath || title)}`,
    title,
    target: { ...target },
    contentEntries: contentEntries.map(normalizeContentEntry),
    workspacePath: workspace.workspacePath ?? "",
    extractPath: workspace.extractPath ?? "",
    operations: [],
  };
}

export function createStageOperation(sourceFile, targetDirectory = "") {
  const sourceDisplayPath = String(sourceFile.path ?? sourceFile.name ?? "");
  const sourcePath = String(sourceFile.absolutePath ?? sourceDisplayPath);
  const sourceName = String(sourceFile.name ?? sourcePath.split(/[\\/]/).at(-1) ?? "file");
  const targetPath = normalizePckTarget([targetDirectory, sourceName].join("/"));

  return createStageOperationRecord(sourceFile, targetPath, sourceDisplayPath, sourcePath, sourceName);
}

export function createStageOperationAtPath(sourceFile, targetPath) {
  const sourceDisplayPath = String(sourceFile.path ?? sourceFile.name ?? "");
  const sourcePath = String(sourceFile.absolutePath ?? sourceDisplayPath);
  const sourceName = String(sourceFile.name ?? sourcePath.split(/[\\/]/).at(-1) ?? "file");

  return createStageOperationRecord(
    sourceFile,
    normalizePckTarget(targetPath),
    sourceDisplayPath,
    sourcePath,
    sourceName,
  );
}

function createStageOperationRecord(sourceFile, targetPath, sourceDisplayPath, sourcePath, sourceName) {
  return {
    id: `op-${hashParts(sourcePath, targetPath)}`,
    sourcePath,
    sourceDisplayPath,
    sourceName,
    targetPath,
    displayTarget: targetPath,
    size: Number(sourceFile.size ?? 0),
    action: "add-or-replace",
  };
}

export function nativeDropActionForMode(mode) {
  if (mode === "browser") {
    return "open-game";
  }
  if (mode === "editor") {
    return "add-source";
  }
  return null;
}

export function sourceTransferIndex(value, sourceCount) {
  const normalized = String(value ?? "").trim();
  if (!/^\d+$/.test(normalized)) {
    return null;
  }

  const index = Number(normalized);
  return index >= 0 && index < Number(sourceCount ?? 0) ? index : null;
}

export function sourceSelectionAfterClick(currentSelection = [], path, options = {}) {
  const normalizedPath = normalizePckTarget(path);
  if (!normalizedPath) {
    return [];
  }

  const current = [...new Set(currentSelection.map(normalizePckTarget).filter(Boolean))];
  if (!options.toggle) {
    return [normalizedPath];
  }

  return current.includes(normalizedPath)
    ? current.filter((selectedPath) => selectedPath !== normalizedPath)
    : [...current, normalizedPath];
}

export function sourceSelectionAfterSelectAll(entries = []) {
  return [
    ...new Set(
      entries
        .map((entry) => normalizePckTarget(entry.path ?? entry.name))
        .filter(Boolean),
    ),
  ];
}

export function sourceSelectionForDrag(currentSelection = [], draggedPath) {
  const normalizedPath = normalizePckTarget(draggedPath);
  const current = [...new Set(currentSelection.map(normalizePckTarget).filter(Boolean))];
  return current.includes(normalizedPath) ? current : normalizedPath ? [normalizedPath] : [];
}

export function describeDragStack(paths = []) {
  const names = paths
    .map((path) => normalizePckTarget(path).split("/").filter(Boolean).at(-1))
    .filter(Boolean);
  const count = names.length;

  return {
    count,
    label: count === 1 ? names[0] : `${count} items`,
    names,
  };
}

export function markStageOperationActions(operations = [], contentEntries = []) {
  const existingTargets = new Set(
    contentEntries
      .map((entry) => normalizePckTarget(entry.path ?? entry.name))
      .filter(Boolean),
  );

  return operations.map((operation) => {
    const targetPath = normalizePckTarget(operation.targetPath);
    return {
      ...operation,
      targetPath,
      displayTarget: targetPath,
      action: existingTargets.has(targetPath) ? "replace" : "add",
    };
  });
}

export function describePackProgress(phase, operations = [], backup = false) {
  const normalizedPhase = ["preparing", "backup", "writing", "done", "failed"].includes(phase)
    ? phase
    : "preparing";
  const percents = {
    preparing: 12,
    backup: 28,
    writing: 58,
    done: 100,
    failed: 100,
  };
  const labelKeys = {
    preparing: "packPreparing",
    backup: "packBackingUp",
    writing: "packWriting",
    done: "packDone",
    failed: "packFailed",
  };

  return {
    phase: normalizedPhase,
    labelKey: labelKeys[normalizedPhase],
    percent: percents[normalizedPhase],
    addCount: operations.filter((operation) => operation.action !== "replace").length,
    replaceCount: operations.filter((operation) => operation.action === "replace").length,
    backup: Boolean(backup),
    bytes: operations.reduce((total, operation) => total + Number(operation.size ?? 0), 0),
  };
}

export function stageOperationsForSourcePaths(sourceEntries = [], sourcePaths = [], targetDirectory = "") {
  const seenIds = new Set();
  const operations = [];
  const normalizedFiles = sourceEntries
    .filter((entry) => entry.kind !== "directory")
    .map((entry) => ({
      entry,
      path: normalizePckTarget(entry.path ?? entry.name),
    }))
    .filter((entry) => entry.path);
  const compactSourcePaths = compactSelectedPaths(sourcePaths);

  for (const sourcePath of compactSourcePaths) {
    const sourceRoot = normalizePckTarget(sourcePath);
    if (!sourceRoot) {
      continue;
    }

    const exactFile = normalizedFiles.find(({ path }) => path === sourceRoot);
    const rootName = sourceRoot.split("/").at(-1) ?? "";
    const matchingFiles = exactFile
      ? [exactFile]
      : normalizedFiles.filter(({ path }) => path.startsWith(`${sourceRoot}/`));

    for (const { entry, path: entryPath } of matchingFiles) {
      if (entryPath !== sourceRoot && !entryPath.startsWith(`${sourceRoot}/`)) {
        continue;
      }

      const relativePath =
        entryPath === sourceRoot ? String(entry.name ?? rootName) : entryPath.slice(sourceRoot.length + 1);
      const targetPath = exactFile
        ? normalizePckTarget([targetDirectory, relativePath].join("/"))
        : normalizePckTarget([targetDirectory, rootName, relativePath].join("/"));
      const operation = createStageOperationAtPath(entry, targetPath);
      if (!seenIds.has(operation.id)) {
        operations.push(operation);
        seenIds.add(operation.id);
      }
    }
  }

  return operations;
}

function compactSelectedPaths(paths = []) {
  const normalized = [...new Set(paths.map(normalizePckTarget).filter(Boolean))].sort(
    (a, b) => a.length - b.length || a.localeCompare(b),
  );
  const compacted = [];

  for (const path of normalized) {
    if (!compacted.some((parent) => path.startsWith(`${parent}/`))) {
      compacted.push(path);
    }
  }

  return compacted;
}

export function mergeContentEntriesWithOperations(contentEntries = [], operations = []) {
  const entriesByPath = new Map();

  for (const entry of contentEntries) {
    const normalized = normalizePckTarget(entry.path ?? entry.name);
    if (!normalized) {
      continue;
    }

    entriesByPath.set(normalized, {
      path: normalized,
      name: String(entry.name ?? normalized.split("/").at(-1) ?? "file"),
      size: Number(entry.size ?? 0),
      kind: "file",
    });
  }

  for (const operation of operations) {
    const normalized = normalizePckTarget(operation.targetPath);
    if (!normalized) {
      continue;
    }

    entriesByPath.set(normalized, {
      path: normalized,
      name: String(operation.sourceName ?? normalized.split("/").at(-1) ?? "file"),
      size: Number(operation.size ?? 0),
      kind: "file",
    });
  }

  return [...entriesByPath.values()].sort((a, b) => a.path.localeCompare(b.path));
}

function normalizeContentEntry(entry) {
  const path = normalizePckTarget(entry.path ?? entry.name);
  return {
    path,
    name: String(entry.name ?? path.split("/").at(-1) ?? "file"),
    size: Number(entry.size ?? 0),
    kind: "file",
  };
}

function normalizeDialogSelection(selected) {
  if (Array.isArray(selected)) {
    return selected;
  }
  return selected ? [selected] : [];
}

export function summarizeOperations(operations) {
  return {
    count: operations.length,
    bytes: operations.reduce((total, operation) => total + Number(operation.size ?? 0), 0),
    targets: operations.map((operation) => normalizePckTarget(operation.targetPath)),
  };
}

export function formatBytes(bytes) {
  const value = Number(bytes ?? 0);
  if (value < 1024) {
    return `${value} B`;
  }

  const units = ["KB", "MB", "GB"];
  let size = value / 1024;
  let unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }

  return `${size.toFixed(size >= 10 ? 0 : 1)} ${units[unitIndex]}`;
}

function cloneNode(node) {
  return {
    ...node,
    children: node.children ? node.children.map(cloneNode) : undefined,
  };
}

function sortTree(node) {
  if (!node.children) {
    return;
  }

  node.children.sort((a, b) => {
    if (a.kind !== b.kind) {
      return a.kind === "directory" ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });

  node.children.forEach(sortTree);
}

function hashParts(...parts) {
  const text = parts.join("\0");
  let hash = 5381;

  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 33) ^ text.charCodeAt(index);
  }

  return (hash >>> 0).toString(36);
}
