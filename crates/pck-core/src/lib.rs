use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::{
    env, fs,
    fs::File,
    io,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

const PCK_HEADER_MAGIC: u32 = 0x4350_4447;
const MAX_SUPPORTED_PCK_VERSION: u32 = 3;
const PACK_DIR_ENCRYPTED: u32 = 1 << 0;
const PCK_FILE_ENCRYPTED: u32 = 1 << 0;
const PCK_FILE_DELETED: u32 = 1 << 1;
const PCK_FILE_RELATIVE_BASE: u32 = 1 << 1;
const PCK_FILE_SPARSE_BUNDLE: u32 = 1 << 2;
const PCK_ALIGNMENT: u64 = 32;
const MAX_PCK_FILE_COUNT: u32 = 250_000;
const MAX_PCK_PATH_LENGTH: usize = 4096;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub absolute_path: String,
    pub size: u64,
    pub kind: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PckWorkspace {
    pub workspace_path: String,
    pub extract_path: String,
    pub entries: Vec<FileEntry>,
    pub log: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PckOperation {
    /// "add" (default — write `file` to `target`), "delete" (remove `target`),
    /// or "copy" (clone the existing entry at `source_path` to `target`).
    #[serde(default)]
    pub kind: String,
    /// Filesystem source for an `add` operation.
    #[serde(default)]
    pub file: String,
    /// Existing package path to clone for a `copy`/duplicate operation.
    #[serde(default)]
    pub source_path: String,
    /// Package destination path (or the path to delete).
    pub target: String,
}

const OP_DELETE: &str = "delete";
const OP_COPY: &str = "copy";

#[derive(Clone, Debug)]
struct NativePckMetadata {
    format_version: u32,
    major: u32,
    minor: u32,
    patch: u32,
    flags: u32,
}

#[derive(Clone, Debug)]
struct NativePckEntry {
    path: String,
    offset: u64,
    size: u64,
    flags: u32,
}

#[derive(Clone, Debug)]
struct NativePckArchive {
    metadata: NativePckMetadata,
    entries: Vec<NativePckEntry>,
}

/// Source of a file's bytes when writing a PCK archive.
///
/// New/replacement files come from a caller-provided buffer (`Memory`),
/// while files carried over from the original archive are streamed directly
/// from the source PCK (`Region`) so a multi-GB repack never has to hold the
/// whole archive in memory.
#[derive(Clone, Debug)]
enum PckEntryData {
    Memory(Vec<u8>),
    Region {
        source: PathBuf,
        offset: u64,
        size: u64,
    },
}

impl PckEntryData {
    fn len(&self) -> u64 {
        match self {
            PckEntryData::Memory(data) => data.len() as u64,
            PckEntryData::Region { size, .. } => *size,
        }
    }
}

#[derive(Clone, Debug)]
struct NativePckWriteEntry {
    path: String,
    data: PckEntryData,
    flags: u32,
}

pub fn scan_paths(paths: Vec<String>) -> Result<Vec<FileEntry>, String> {
    let mut entries = Vec::new();

    for path in paths {
        let root = PathBuf::from(path);
        if !root.exists() {
            return Err(format!("Path does not exist: {}", root.display()));
        }
        scan_root(&root, &mut entries)?;
    }

    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}

pub fn list_pck_entries(pck_path: String) -> Result<Vec<FileEntry>, String> {
    let pck_path = PathBuf::from(pck_path);
    if !pck_path.exists() {
        return Err(format!("PCK does not exist: {}", pck_path.display()));
    }

    list_pck_entries_native(&pck_path)
}

pub fn repack_pck(
    pck_path: String,
    operations: Vec<PckOperation>,
    workspace_path: Option<String>,
    backup_original: bool,
) -> Result<String, String> {
    if operations.is_empty() {
        return Err("No staged operations to pack".to_string());
    }

    let pck_path = PathBuf::from(pck_path);
    if !pck_path.exists() {
        return Err(format!("PCK does not exist: {}", pck_path.display()));
    }

    for operation in &operations {
        if operation.target.trim().is_empty() {
            return Err("Empty target path in staged operation".to_string());
        }
        match operation.kind.as_str() {
            OP_DELETE => {}
            OP_COPY => {
                if operation.source_path.trim().is_empty() {
                    return Err(format!("Empty copy source for {}", operation.target));
                }
            }
            _ => {
                // add / replace: the bytes come from a filesystem file.
                let source = PathBuf::from(&operation.file);
                if !source.exists() {
                    return Err(format!("Source file does not exist: {}", source.display()));
                }
                clear_quarantine(&source);
            }
        }
    }

    let mut cleanup_log = String::new();
    let staged_operations = if let Some(workspace_path) = workspace_path.as_deref() {
        stage_operations_in_workspace(workspace_path, &operations)?
    } else {
        operations.clone()
    };

    let mut log = repack_pck_with_options(&pck_path, &staged_operations, backup_original)?;

    if let Some(workspace_path) = workspace_path {
        cleanup_workspace(&PathBuf::from(workspace_path))?;
        cleanup_log.push_str("\nWorkspace cleanup: removed temp extraction workspace");
    }

    log.push_str(&cleanup_log);
    Ok(log)
}

pub fn open_pck_workspace(pck_path: String) -> Result<PckWorkspace, String> {
    let pck_path = PathBuf::from(pck_path);
    if !pck_path.exists() {
        return Err(format!("PCK does not exist: {}", pck_path.display()));
    }

    let workspace_path = create_workspace_path(&pck_path)?;
    let extract_path = workspace_path.join("contents");
    fs::create_dir_all(&extract_path).map_err(|error| io_error("create", &extract_path, error))?;

    let entries = match extract_pck_native(&pck_path, &extract_path) {
        Ok(entries) => entries,
        Err(native_error) => {
            let _ = cleanup_workspace(&workspace_path);
            return Err(native_error);
        }
    };
    let log = format!(
        "Backend: built-in Rust PCK reader\nPCK: {}",
        pck_path.display()
    );

    Ok(PckWorkspace {
        workspace_path: workspace_path.to_string_lossy().to_string(),
        extract_path: extract_path.to_string_lossy().to_string(),
        entries,
        log,
    })
}

pub fn extract_pck_paths(
    pck_path: String,
    destination_path: String,
    selected_paths: Vec<String>,
) -> Result<Vec<FileEntry>, String> {
    if selected_paths.is_empty() {
        return Err("No PCK paths selected for extraction".to_string());
    }

    let pck_path = PathBuf::from(pck_path);
    if !pck_path.exists() {
        return Err(format!("PCK does not exist: {}", pck_path.display()));
    }

    let destination_path = PathBuf::from(destination_path);
    fs::create_dir_all(&destination_path)
        .map_err(|error| io_error("create", &destination_path, error))?;

    let selected_paths = selected_paths
        .iter()
        .map(|path| normalize_package_target(path))
        .collect::<Result<Vec<_>, _>>()?;

    extract_pck_paths_native(&pck_path, &destination_path, &selected_paths)
}

pub fn cleanup_pck_workspace(workspace_path: String) -> Result<String, String> {
    let workspace_path = PathBuf::from(workspace_path);
    cleanup_workspace(&workspace_path)?;
    Ok(format!("Workspace removed: {}", workspace_path.display()))
}

fn load_pck_archive(path: &Path) -> Result<NativePckArchive, String> {
    let mut file = File::open(path).map_err(|error| io_error("open", path, error))?;
    let file_len = file
        .metadata()
        .map_err(|error| io_error("metadata", path, error))?
        .len();
    let pck_start = file
        .stream_position()
        .map_err(|error| io_error("seek", path, error))?;

    let magic = read_u32(&mut file, path)?;
    if magic != PCK_HEADER_MAGIC {
        return Err("Built-in PCK backend could not read this file: invalid PCK magic".to_string());
    }

    let format_version = read_u32(&mut file, path)?;
    let major = read_u32(&mut file, path)?;
    let minor = read_u32(&mut file, path)?;
    let patch = read_u32(&mut file, path)?;

    if format_version > MAX_SUPPORTED_PCK_VERSION {
        return Err(format!(
            "Built-in PCK backend supports PCK format up to {}, found {}",
            MAX_SUPPORTED_PCK_VERSION, format_version
        ));
    }

    let mut flags = 0;
    let mut file_offset_base = 0;
    if format_version >= 2 {
        flags = read_u32(&mut file, path)?;
        file_offset_base = read_u64(&mut file, path)?;
    }

    if flags & PACK_DIR_ENCRYPTED != 0 {
        return Err("Built-in PCK backend does not support encrypted PCK directories".to_string());
    }

    if flags & PCK_FILE_SPARSE_BUNDLE != 0 {
        return Err("Built-in PCK backend does not support sparse PCK bundles yet".to_string());
    }

    if format_version >= 3 || (format_version == 2 && flags & PCK_FILE_RELATIVE_BASE != 0) {
        file_offset_base = file_offset_base
            .checked_add(pck_start)
            .ok_or_else(|| "PCK file offset overflow".to_string())?;
    }

    if format_version >= 3 {
        let directory_offset = read_u64(&mut file, path)?;
        file.seek(SeekFrom::Start(
            pck_start
                .checked_add(directory_offset)
                .ok_or_else(|| "PCK directory offset overflow".to_string())?,
        ))
        .map_err(|error| io_error("seek", path, error))?;
    } else {
        for _ in 0..16 {
            read_u32(&mut file, path)?;
        }
    }

    let file_count = read_u32(&mut file, path)?;
    if file_count > MAX_PCK_FILE_COUNT {
        return Err(format!("PCK directory has too many files: {}", file_count));
    }
    let mut entries = Vec::with_capacity(file_count as usize);

    for _ in 0..file_count {
        let path_len = read_u32(&mut file, path)? as usize;
        if path_len > MAX_PCK_PATH_LENGTH {
            return Err(format!("PCK entry path is too long: {} bytes", path_len));
        }
        let mut raw_path = vec![0; path_len];
        file.read_exact(&mut raw_path)
            .map_err(|error| io_error("read", path, error))?;
        while raw_path.last() == Some(&0) {
            raw_path.pop();
        }
        let entry_path = String::from_utf8(raw_path)
            .map_err(|error| format!("PCK path is not valid UTF-8: {}", error))?;

        let relative_offset = read_u64(&mut file, path)?;
        let size = read_u64(&mut file, path)?;
        let mut md5_buffer = [0; 16];
        file.read_exact(&mut md5_buffer)
            .map_err(|error| io_error("read", path, error))?;

        let entry_flags = if format_version >= 2 {
            read_u32(&mut file, path)?
        } else {
            0
        };

        if entry_flags & PCK_FILE_ENCRYPTED != 0 {
            return Err(format!(
                "Built-in PCK backend does not support encrypted PCK file: {}",
                entry_path
            ));
        }

        let offset = file_offset_base
            .checked_add(relative_offset)
            .ok_or_else(|| "PCK file entry offset overflow".to_string())?;
        let end = offset
            .checked_add(size)
            .ok_or_else(|| format!("PCK file entry size overflow: {}", entry_path))?;
        if end > file_len {
            return Err(format!(
                "PCK file entry exceeds archive length: {}",
                entry_path
            ));
        }

        entries.push(NativePckEntry {
            path: entry_path,
            offset,
            size,
            flags: entry_flags,
        });
    }

    Ok(NativePckArchive {
        metadata: NativePckMetadata {
            format_version,
            major,
            minor,
            patch,
            flags,
        },
        entries,
    })
}

fn extract_pck_native(pck_path: &Path, extract_path: &Path) -> Result<Vec<FileEntry>, String> {
    let archive = load_pck_archive(pck_path)?;
    fs::create_dir_all(extract_path).map_err(|error| io_error("create", extract_path, error))?;

    let mut source = File::open(pck_path).map_err(|error| io_error("open", pck_path, error))?;
    let mut entries = Vec::new();

    for entry in archive
        .entries
        .iter()
        .filter(|entry| entry.flags & PCK_FILE_DELETED == 0)
    {
        let visible_path = normalize_package_target(&entry.path)?;
        let target_path = safe_package_path(extract_path, &visible_path)?;
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent).map_err(|error| io_error("create", parent, error))?;
        }

        source
            .seek(SeekFrom::Start(entry.offset))
            .map_err(|error| io_error("seek", pck_path, error))?;
        let mut limited = (&mut source).take(entry.size);
        let mut output =
            File::create(&target_path).map_err(|error| io_error("create", &target_path, error))?;
        io::copy(&mut limited, &mut output)
            .map_err(|error| io_error("copy", &target_path, error))?;

        entries.push(FileEntry {
            name: visible_path
                .split('/')
                .last()
                .filter(|name| !name.is_empty())
                .unwrap_or("file")
                .to_string(),
            path: visible_path,
            absolute_path: target_path.to_string_lossy().to_string(),
            size: entry.size,
            kind: "file".to_string(),
        });
    }

    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}

fn extract_pck_paths_native(
    pck_path: &Path,
    destination_path: &Path,
    selected_paths: &[String],
) -> Result<Vec<FileEntry>, String> {
    let archive = load_pck_archive(pck_path)?;
    let mut source = File::open(pck_path).map_err(|error| io_error("open", pck_path, error))?;
    let mut entries = Vec::new();

    for entry in archive
        .entries
        .iter()
        .filter(|entry| entry.flags & PCK_FILE_DELETED == 0)
    {
        let visible_path = normalize_package_target(&entry.path)?;
        if !selected_paths
            .iter()
            .any(|selected| package_path_matches_selection(&visible_path, selected))
        {
            continue;
        }

        let target_path = safe_package_path(destination_path, &visible_path)?;
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent).map_err(|error| io_error("create", parent, error))?;
        }

        source
            .seek(SeekFrom::Start(entry.offset))
            .map_err(|error| io_error("seek", pck_path, error))?;
        let mut limited = (&mut source).take(entry.size);
        let mut output =
            File::create(&target_path).map_err(|error| io_error("create", &target_path, error))?;
        io::copy(&mut limited, &mut output)
            .map_err(|error| io_error("copy", &target_path, error))?;

        entries.push(FileEntry {
            name: visible_path
                .split('/')
                .last()
                .filter(|name| !name.is_empty())
                .unwrap_or("file")
                .to_string(),
            path: visible_path,
            absolute_path: target_path.to_string_lossy().to_string(),
            size: entry.size,
            kind: "file".to_string(),
        });
    }

    if entries.is_empty() {
        return Err("Selected PCK paths did not match any files".to_string());
    }

    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}

fn package_path_matches_selection(path: &str, selected: &str) -> bool {
    path == selected || path.starts_with(&format!("{}/", selected))
}

fn list_pck_entries_native(pck_path: &Path) -> Result<Vec<FileEntry>, String> {
    let archive = load_pck_archive(pck_path)?;
    let mut entries = Vec::new();

    for entry in archive
        .entries
        .iter()
        .filter(|entry| entry.flags & PCK_FILE_DELETED == 0)
    {
        let visible_path = normalize_package_target(&entry.path)?;
        entries.push(FileEntry {
            name: visible_path
                .split('/')
                .last()
                .filter(|name| !name.is_empty())
                .unwrap_or("file")
                .to_string(),
            path: visible_path,
            absolute_path: String::new(),
            size: entry.size,
            kind: "file".to_string(),
        });
    }

    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}

fn repack_pck_native(pck_path: &Path, operations: &[PckOperation]) -> Result<String, String> {
    let archive = load_pck_archive(pck_path)?;
    let mut files: BTreeMap<String, NativePckWriteEntry> = BTreeMap::new();

    // Carry surviving entries over by reference: the writer streams their bytes
    // straight out of the original PCK instead of loading them into memory.
    for entry in archive
        .entries
        .iter()
        .filter(|entry| entry.flags & PCK_FILE_DELETED == 0)
    {
        files.insert(
            entry.path.clone(),
            NativePckWriteEntry {
                path: entry.path.clone(),
                data: PckEntryData::Region {
                    source: pck_path.to_path_buf(),
                    offset: entry.offset,
                    size: entry.size,
                },
                flags: entry.flags & !PCK_FILE_ENCRYPTED,
            },
        );
    }

    // Operations are applied in order so a later op can build on an earlier one
    // (e.g. delete then re-add, or copy from a just-added entry).
    for operation in operations {
        let target = pck_archive_path(&operation.target)?;
        match operation.kind.as_str() {
            OP_DELETE => {
                files.remove(&target);
            }
            OP_COPY => {
                let source = pck_archive_path(&operation.source_path)?;
                let cloned = files.get(&source).ok_or_else(|| {
                    format!("Copy source not found in package: {}", operation.source_path)
                })?;
                let data = cloned.data.clone();
                let flags = cloned.flags;
                files.insert(
                    target.clone(),
                    NativePckWriteEntry {
                        path: target,
                        data,
                        flags,
                    },
                );
            }
            _ => {
                let data = fs::read(&operation.file)
                    .map_err(|error| io_error("read", &PathBuf::from(&operation.file), error))?;
                files.insert(
                    target.clone(),
                    NativePckWriteEntry {
                        path: target,
                        data: PckEntryData::Memory(data),
                        flags: 0,
                    },
                );
            }
        }
    }

    write_native_pck_archive(pck_path, archive.metadata, files.into_values().collect())?;
    Ok(format!(
        "PCK: {}\nBackend: built-in Rust PCK writer\nOperations: {}",
        pck_path.display(),
        operations.len()
    ))
}

fn repack_pck_with_options(
    pck_path: &Path,
    operations: &[PckOperation],
    backup_original: bool,
) -> Result<String, String> {
    let backup_path = if backup_original {
        Some(create_pck_backup(pck_path)?)
    } else {
        None
    };

    let mut log = repack_pck_native(pck_path, operations)?;
    if let Some(backup_path) = backup_path {
        log.push_str(&format!("\nBackup: {}", backup_path.display()));
    }
    Ok(log)
}

fn create_pck_backup(pck_path: &Path) -> Result<PathBuf, String> {
    let backup_path = pck_path.with_extension(format!(
        "{}.{}.bak",
        pck_path
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("pck"),
        timestamp_millis()?
    ));
    fs::copy(pck_path, &backup_path).map_err(|error| io_error("copy", pck_path, error))?;
    // Flush the backup to stable storage before we touch the original, so a
    // crash mid-repack can never leave us without a recoverable copy.
    File::open(&backup_path)
        .and_then(|file| file.sync_all())
        .map_err(|error| io_error("sync", &backup_path, error))?;
    Ok(backup_path)
}

fn write_native_pck_archive(
    pck_path: &Path,
    metadata: NativePckMetadata,
    entries: Vec<NativePckWriteEntry>,
) -> Result<(), String> {
    if metadata.format_version > MAX_SUPPORTED_PCK_VERSION {
        return Err(format!(
            "Built-in PCK backend cannot write PCK format {}",
            metadata.format_version
        ));
    }

    // Write to a unique temp file beside the target, fsync it, then atomically
    // rename over the original. On any error the temp file is removed so a
    // failed repack never leaves debris next to the user's data.
    let tmp_path = unique_temp_path(pck_path)?;
    match write_native_pck_to(&tmp_path, &metadata, entries) {
        Ok(()) => {
            fs::rename(&tmp_path, pck_path).map_err(|error| {
                let _ = fs::remove_file(&tmp_path);
                io_error("rename", pck_path, error)
            })?;
            sync_parent_dir(pck_path);
            Ok(())
        }
        Err(error) => {
            let _ = fs::remove_file(&tmp_path);
            Err(error)
        }
    }
}

fn write_native_pck_to(
    tmp_path: &Path,
    metadata: &NativePckMetadata,
    mut entries: Vec<NativePckWriteEntry>,
) -> Result<(), String> {
    let mut file = File::create(tmp_path).map_err(|error| io_error("create", tmp_path, error))?;
    entries.sort_by(|a, b| a.path.cmp(&b.path));

    write_u32(&mut file, PCK_HEADER_MAGIC, tmp_path)?;
    write_u32(&mut file, metadata.format_version, tmp_path)?;
    write_u32(&mut file, metadata.major, tmp_path)?;
    write_u32(&mut file, metadata.minor, tmp_path)?;
    write_u32(&mut file, metadata.patch, tmp_path)?;

    let mut base_offset_position = 0;
    let mut directory_offset_position = 0;
    let use_relative_offset =
        metadata.flags & PCK_FILE_RELATIVE_BASE != 0 || metadata.format_version >= 3;

    if metadata.format_version >= 2 {
        let mut flags = metadata.flags & !(PACK_DIR_ENCRYPTED | PCK_FILE_SPARSE_BUNDLE);
        if use_relative_offset {
            flags |= PCK_FILE_RELATIVE_BASE;
        }
        write_u32(&mut file, flags, tmp_path)?;
        base_offset_position = file
            .stream_position()
            .map_err(|error| io_error("seek", tmp_path, error))?;
        write_u64(&mut file, 0, tmp_path)?;

        if metadata.format_version >= 3 {
            directory_offset_position = file
                .stream_position()
                .map_err(|error| io_error("seek", tmp_path, error))?;
            write_u64(&mut file, 0, tmp_path)?;
        }
    }

    for _ in 0..16 {
        write_u32(&mut file, 0, tmp_path)?;
    }

    let directory_start = file
        .stream_position()
        .map_err(|error| io_error("seek", tmp_path, error))?;
    if metadata.format_version >= 3 {
        file.seek(SeekFrom::Start(directory_offset_position))
            .map_err(|error| io_error("seek", tmp_path, error))?;
        write_u64(&mut file, directory_start, tmp_path)?;
        file.seek(SeekFrom::Start(directory_start))
            .map_err(|error| io_error("seek", tmp_path, error))?;
    }

    write_u32(&mut file, entries.len() as u32, tmp_path)?;
    let mut offset_patch_positions = Vec::with_capacity(entries.len());

    for entry in &entries {
        let path_bytes = entry.path.as_bytes();
        // Godot pads the stored path up to a 4-byte boundary; an already
        // aligned path gets NO padding. Computing `4 - (len % 4)` here would
        // append a spurious 4 NUL bytes and produce a non-conforming archive.
        let path_padding = match path_bytes.len() % 4 {
            0 => 0,
            remainder => 4 - remainder,
        };
        let path_len = path_bytes.len() + path_padding;
        write_u32(&mut file, path_len as u32, tmp_path)?;
        file.write_all(path_bytes)
            .map_err(|error| io_error("write", tmp_path, error))?;
        if path_padding > 0 {
            file.write_all(&vec![0; path_padding])
                .map_err(|error| io_error("write", tmp_path, error))?;
        }

        let offset_position = file
            .stream_position()
            .map_err(|error| io_error("seek", tmp_path, error))?;
        offset_patch_positions.push(offset_position);
        write_u64(&mut file, 0, tmp_path)?;
        write_u64(&mut file, entry.data.len(), tmp_path)?;
        file.write_all(&[0; 16])
            .map_err(|error| io_error("write", tmp_path, error))?;

        if metadata.format_version >= 2 {
            write_u32(&mut file, entry.flags & !PCK_FILE_ENCRYPTED, tmp_path)?;
        }
    }

    // Godot aligns pack data to a fixed boundary for EVERY format version (16 on
    // PCK 1 / Godot 3, 32 on PCK ≥ 2 / Godot 4). The old code only aligned PCK ≥ 2,
    // so rewriting a Godot 3 pack produced unaligned data and the game failed to
    // load some resources (blank menu text). Align for all versions.
    let alignment = pck_data_alignment(metadata.format_version);
    pad_to_alignment(&mut file, tmp_path, alignment)?;
    let files_start = file
        .stream_position()
        .map_err(|error| io_error("seek", tmp_path, error))?;

    if metadata.format_version >= 2 {
        file.seek(SeekFrom::Start(base_offset_position))
            .map_err(|error| io_error("seek", tmp_path, error))?;
        write_u64(&mut file, files_start, tmp_path)?;
        file.seek(SeekFrom::Start(files_start))
            .map_err(|error| io_error("seek", tmp_path, error))?;
    }

    let mut written = Vec::with_capacity(entries.len());
    let mut source_cache: HashMap<PathBuf, File> = HashMap::new();
    for entry in &entries {
        pad_to_alignment(&mut file, tmp_path, alignment)?;

        let absolute_offset = file
            .stream_position()
            .map_err(|error| io_error("seek", tmp_path, error))?;

        let (size, md5): (u64, [u8; 16]) = match &entry.data {
            PckEntryData::Memory(data) => {
                file.write_all(data)
                    .map_err(|error| io_error("write", tmp_path, error))?;
                let mut hasher = Md5::new();
                hasher.update(data);
                (data.len() as u64, hasher.finalize().into())
            }
            PckEntryData::Region {
                source,
                offset,
                size,
            } => {
                if !source_cache.contains_key(source) {
                    let handle =
                        File::open(source).map_err(|error| io_error("open", source, error))?;
                    source_cache.insert(source.clone(), handle);
                }
                let reader = source_cache
                    .get_mut(source)
                    .expect("source handle was just cached");
                let md5 = copy_region_hashing(reader, &mut file, *offset, *size, source, tmp_path)?;
                (*size, md5)
            }
        };

        let stored_offset = if metadata.format_version < 2 {
            absolute_offset
        } else {
            absolute_offset
                .checked_sub(files_start)
                .ok_or_else(|| "PCK stored offset underflow".to_string())?
        };
        written.push((stored_offset, size, md5));
    }

    for (offset_position, (stored_offset, size, md5)) in
        offset_patch_positions.into_iter().zip(written.into_iter())
    {
        file.seek(SeekFrom::Start(offset_position))
            .map_err(|error| io_error("seek", tmp_path, error))?;
        write_u64(&mut file, stored_offset, tmp_path)?;
        write_u64(&mut file, size, tmp_path)?;
        file.write_all(&md5)
            .map_err(|error| io_error("write", tmp_path, error))?;
    }

    file.flush()
        .map_err(|error| io_error("flush", tmp_path, error))?;
    file.sync_all()
        .map_err(|error| io_error("sync", tmp_path, error))?;
    Ok(())
}

/// Stream `size` bytes from `source` at `offset` into `dest`, returning the
/// MD5 of the copied bytes. Uses a fixed buffer so repacking a multi-GB PCK
/// never materialises an entry in memory.
fn copy_region_hashing(
    source: &mut File,
    dest: &mut File,
    offset: u64,
    size: u64,
    source_path: &Path,
    dest_path: &Path,
) -> Result<[u8; 16], String> {
    source
        .seek(SeekFrom::Start(offset))
        .map_err(|error| io_error("seek", source_path, error))?;
    let mut hasher = Md5::new();
    let mut remaining = size;
    let mut buffer = [0u8; 65536];
    while remaining > 0 {
        let want = remaining.min(buffer.len() as u64) as usize;
        source
            .read_exact(&mut buffer[..want])
            .map_err(|error| io_error("read", source_path, error))?;
        hasher.update(&buffer[..want]);
        dest.write_all(&buffer[..want])
            .map_err(|error| io_error("write", dest_path, error))?;
        remaining -= want as u64;
    }
    Ok(hasher.finalize().into())
}

/// A unique hidden temp path in the same directory as `pck_path`, so the final
/// rename is atomic (same filesystem) and never clashes with a concurrent run
/// or a stale leftover.
fn unique_temp_path(pck_path: &Path) -> Result<PathBuf, String> {
    let file_name = pck_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("Invalid PCK path: {}", pck_path.display()))?;
    let temp_name = format!(
        ".{}.{}.{}.tmp",
        file_name,
        std::process::id(),
        timestamp_millis()?
    );
    Ok(match pck_path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(temp_name),
        _ => PathBuf::from(temp_name),
    })
}

/// Best-effort fsync of the directory holding `path` so the rename itself is
/// durable across a power loss. Failures are ignored — the data write already
/// succeeded and not every platform/filesystem supports directory sync.
fn sync_parent_dir(path: &Path) {
    if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        if let Ok(dir) = File::open(parent) {
            let _ = dir.sync_all();
        }
    }
}

fn pck_archive_path(target: &str) -> Result<String, String> {
    let normalized = normalize_package_target(target)?;
    Ok(format!("res://{}", normalized))
}

fn read_u32(file: &mut File, path: &Path) -> Result<u32, String> {
    let mut buffer = [0; 4];
    file.read_exact(&mut buffer)
        .map_err(|error| io_error("read", path, error))?;
    Ok(u32::from_le_bytes(buffer))
}

fn read_u64(file: &mut File, path: &Path) -> Result<u64, String> {
    let mut buffer = [0; 8];
    file.read_exact(&mut buffer)
        .map_err(|error| io_error("read", path, error))?;
    Ok(u64::from_le_bytes(buffer))
}

fn write_u32(file: &mut File, value: u32, path: &Path) -> Result<(), String> {
    file.write_all(&value.to_le_bytes())
        .map_err(|error| io_error("write", path, error))
}

fn write_u64(file: &mut File, value: u64, path: &Path) -> Result<(), String> {
    file.write_all(&value.to_le_bytes())
        .map_err(|error| io_error("write", path, error))
}

fn pad_to_alignment(file: &mut File, path: &Path, alignment: u64) -> Result<(), String> {
    if alignment <= 1 {
        return Ok(());
    }
    while file
        .stream_position()
        .map_err(|error| io_error("seek", path, error))?
        % alignment
        != 0
    {
        file.write_all(&[0])
            .map_err(|error| io_error("write", path, error))?;
    }
    Ok(())
}

/// Byte boundary each file's data is padded to. Godot aligns pack data so a
/// file always begins on this boundary; reproducing it is REQUIRED — Godot 3
/// (PCK format 1) uses 16, Godot 4 (PCK format ≥ 2) uses 32. Writing an
/// unaligned PCK 1 made Godot 3.5 fail to load some resources (e.g. menu font
/// atlases), which showed up as blank UI text.
fn pck_data_alignment(format_version: u32) -> u64 {
    if format_version >= 2 {
        PCK_ALIGNMENT
    } else {
        16
    }
}

fn scan_root(root: &Path, entries: &mut Vec<FileEntry>) -> Result<(), String> {
    let metadata = fs::symlink_metadata(root).map_err(|error| io_error("metadata", root, error))?;
    if metadata.file_type().is_symlink() {
        return Err(format!("Refusing to scan symlink: {}", root.display()));
    }

    if metadata.is_file() {
        push_file(root, root, entries)?;
        return Ok(());
    }

    if metadata.is_dir() {
        scan_directory(root, root, entries)?;
    }

    Ok(())
}

pub fn is_game_dialog_selection(path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default();

    extension.eq_ignore_ascii_case("pck") && path.is_file()
        || extension.eq_ignore_ascii_case("app") && path.is_dir()
}

fn scan_directory(root: &Path, current: &Path, entries: &mut Vec<FileEntry>) -> Result<(), String> {
    let children = fs::read_dir(current).map_err(|error| io_error("read", current, error))?;
    for child in children {
        let child = child.map_err(|error| io_error("read child", current, error))?;
        let path = child.path();
        let metadata =
            fs::symlink_metadata(&path).map_err(|error| io_error("metadata", &path, error))?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            scan_directory(root, &path, entries)?;
        } else if metadata.is_file() {
            push_file(root, &path, entries)?;
        }
    }
    Ok(())
}

fn push_file(root: &Path, path: &Path, entries: &mut Vec<FileEntry>) -> Result<(), String> {
    let metadata = fs::metadata(path).map_err(|error| io_error("metadata", path, error))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("file")
        .to_string();

    entries.push(FileEntry {
        name,
        path: display_path(root, path),
        absolute_path: path.to_string_lossy().to_string(),
        size: metadata.len(),
        kind: "file".to_string(),
    });

    Ok(())
}

fn display_path(root: &Path, path: &Path) -> String {
    let root_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("root");
    let relative = path.strip_prefix(root).unwrap_or(path);
    let display = if relative.as_os_str().is_empty() {
        PathBuf::from(root_name)
    } else {
        PathBuf::from(root_name).join(relative)
    };

    normalize_separators(display)
}

fn normalize_separators(path: PathBuf) -> String {
    path.components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("/")
}

fn create_workspace_path(pck_path: &Path) -> Result<PathBuf, String> {
    let stem = pck_path
        .file_stem()
        .and_then(|name| name.to_str())
        .map(sanitize_filename)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "pck".to_string());
    Ok(env::temp_dir()
        .join("GodotPCKStudio")
        .join(format!("{}-{}", stem, timestamp_millis()?)))
}

fn stage_operations_in_workspace(
    workspace_path: &str,
    operations: &[PckOperation],
) -> Result<Vec<PckOperation>, String> {
    let workspace_path = PathBuf::from(workspace_path);
    let extract_path = workspace_path.join("contents");
    if !extract_path.exists() {
        return Err(format!(
            "Workspace contents directory does not exist: {}",
            extract_path.display()
        ));
    }

    operations
        .iter()
        .map(|operation| {
            // delete/copy operations carry no filesystem source — pass them through.
            if operation.kind == OP_DELETE || operation.kind == OP_COPY {
                return Ok(operation.clone());
            }

            let source = PathBuf::from(&operation.file);
            if !source.exists() {
                return Err(format!("Source file does not exist: {}", source.display()));
            }

            let target_path = safe_package_path(&extract_path, &operation.target)?;
            if let Some(parent) = target_path.parent() {
                fs::create_dir_all(parent).map_err(|error| io_error("create", parent, error))?;
            }
            fs::copy(&source, &target_path)
                .map_err(|error| io_error("copy", &target_path, error))?;

            Ok(PckOperation {
                file: target_path.to_string_lossy().to_string(),
                target: normalize_target(&operation.target),
                ..Default::default()
            })
        })
        .collect()
}

fn safe_package_path(root: &Path, target: &str) -> Result<PathBuf, String> {
    let normalized = normalize_package_target(target)?;

    let mut path = root.to_path_buf();
    for part in normalized.split('/') {
        path.push(part);
    }
    Ok(path)
}

fn normalize_package_target(target: &str) -> Result<String, String> {
    let normalized_slashes = target.replace('\\', "/");
    let stripped = normalized_slashes
        .strip_prefix("res://")
        .unwrap_or(&normalized_slashes)
        .trim_start_matches('/');
    let mut parts = Vec::new();

    for part in stripped.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." || part.contains('\0') {
            return Err(format!("Unsafe target path: {}", target));
        }
        parts.push(part);
    }

    if parts.is_empty() {
        return Err("Target path is empty".to_string());
    }

    Ok(parts.join("/"))
}

fn normalize_target(target: &str) -> String {
    target
        .replace('\\', "/")
        .trim_start_matches("res://")
        .trim_start_matches('/')
        .split('/')
        .filter(|part| !part.is_empty() && *part != "." && *part != "..")
        .collect::<Vec<_>>()
        .join("/")
}

fn cleanup_workspace(path: &Path) -> Result<(), String> {
    let root = env::temp_dir().join("GodotPCKStudio");
    fs::create_dir_all(&root).map_err(|error| io_error("create", &root, error))?;
    let root = fs::canonicalize(&root).map_err(|error| io_error("canonicalize", &root, error))?;
    let path = fs::canonicalize(path).map_err(|error| io_error("canonicalize", path, error))?;

    if path == root {
        return Err("Refusing to cleanup the workspace root".to_string());
    }

    if !path.starts_with(&root) {
        return Err(format!(
            "Refusing to cleanup outside workspace root: {}",
            path.display()
        ));
    }

    fs::remove_dir_all(&path).map_err(|error| io_error("remove", &path, error))?;

    if path.exists() {
        return Err(format!("Workspace cleanup failed: {}", path.display()));
    }

    Ok(())
}

pub fn timestamp_millis() -> Result<u128, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .map_err(|error| format!("Clock error: {}", error))
}

pub fn sanitize_label(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
        .collect()
}

fn sanitize_filename(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '-'
            }
        })
        .collect()
}

/// Best-effort removal of the macOS quarantine attribute from a staged source
/// file. This is a convenience so dragged-in downloads don't carry quarantine
/// into the repack; if `xattr` is missing or the volume is read-only it must
/// NOT abort the repack, so all failures are ignored.
fn clear_quarantine(path: &Path) {
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("xattr")
            .arg("-dr")
            .arg("com.apple.quarantine")
            .arg(path)
            .output();
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
    }
}

fn io_error(action: &str, path: &Path, error: io::Error) -> String {
    format!("Could not {} {}: {}", action, path.display(), error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_package_path_rejects_parent_traversal() {
        let root = PathBuf::from("/tmp/GodotPCKStudio/example/contents");
        let result = safe_package_path(&root, "../outside.txt");

        assert!(result.is_err());
    }

    #[test]
    fn safe_package_path_keeps_targets_inside_workspace() {
        let root = PathBuf::from("/tmp/GodotPCKStudio/example/contents");
        let result = safe_package_path(&root, "locale/ru.po").unwrap();

        assert_eq!(result, root.join("locale").join("ru.po"));
    }

    #[test]
    fn pck_archive_path_rejects_parent_traversal() {
        let result = pck_archive_path("../escape.txt");

        assert!(result.is_err());
    }

    #[test]
    fn normalize_target_keeps_command_targets_relative() {
        assert_eq!(normalize_target("res://locale/ru.po"), "locale/ru.po");
        assert_eq!(normalize_target("/locale/ru.po"), "locale/ru.po");
    }

    #[test]
    fn cleanup_pck_workspace_rejects_paths_outside_temp_workspace() {
        let result = cleanup_pck_workspace("/tmp/not-godot-pck-studio".to_string());

        assert!(result.is_err());
    }

    #[test]
    fn cleanup_pck_workspace_rejects_parent_traversal_inside_workspace_root() {
        let outside = create_test_dir("cleanup-outside");
        let root = env::temp_dir().join("GodotPCKStudio");
        fs::create_dir_all(&root).unwrap();
        let traversal = root.join("..").join(outside.file_name().unwrap());

        let result = cleanup_workspace(&traversal);

        assert!(result.is_err());
        assert!(outside.exists());
        fs::remove_dir_all(outside).unwrap();
    }

    #[test]
    fn sanitize_label_keeps_window_labels_to_safe_ascii() {
        assert_eq!(sanitize_label("abc-DEF_123:/../x"), "abc-DEF_123x");
    }

    #[cfg(unix)]
    #[test]
    fn scan_paths_ignores_symlinked_files_and_directories() {
        use std::os::unix::fs::symlink;

        let root = create_test_dir("symlink-scan");
        let outside = create_test_dir("symlink-outside");
        fs::create_dir_all(outside.join("nested")).unwrap();
        fs::write(outside.join("nested/secret.txt"), b"secret").unwrap();
        fs::write(outside.join("loose.txt"), b"loose").unwrap();
        symlink(outside.join("nested"), root.join("linked-dir")).unwrap();
        symlink(outside.join("loose.txt"), root.join("linked-file.txt")).unwrap();
        fs::write(root.join("real.txt"), b"real").unwrap();

        let entries = scan_paths(vec![root.to_string_lossy().to_string()]).unwrap();
        let paths = entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();

        assert!(paths.iter().any(|path| path.ends_with("real.txt")));
        assert!(!paths.iter().any(|path| path.contains("linked-dir")));
        assert!(!paths.iter().any(|path| path.contains("linked-file")));
    }

    #[test]
    fn scan_paths_recurses_into_macos_app_bundles() {
        let root = create_test_dir("app-scan");
        let app_resources = root.join("The Case.app/Contents/Resources");
        fs::create_dir_all(&app_resources).unwrap();
        fs::write(app_resources.join("The Case.pck"), b"pck").unwrap();

        let entries = scan_paths(vec![root
            .join("The Case.app")
            .to_string_lossy()
            .to_string()])
        .unwrap();
        let paths = entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();

        assert!(paths.contains(&"The Case.app/Contents/Resources/The Case.pck"));
    }

    #[test]
    fn game_dialog_selection_accepts_only_app_bundles_and_pck_files() {
        let root = create_test_dir("game-dialog-selection");
        let app_root = root.join("The Case.app");
        let pck_path = root.join("game.pck");
        let text_path = root.join("notes.txt");
        let ordinary_folder = root.join("SavesDir");

        fs::create_dir_all(&app_root).unwrap();
        fs::create_dir_all(&ordinary_folder).unwrap();
        fs::write(&pck_path, b"pck").unwrap();
        fs::write(&text_path, b"text").unwrap();

        assert!(is_game_dialog_selection(&app_root));
        assert!(is_game_dialog_selection(&pck_path));
        assert!(!is_game_dialog_selection(&text_path));
        assert!(!is_game_dialog_selection(&ordinary_folder));
    }

    #[test]
    fn native_pck_backend_extracts_without_external_tool() {
        let root = create_test_dir("native-extract");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"hello".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        let entries = extract_pck_native(&pck_path, &extract_path).unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "locale/ru.po");
        assert_eq!(
            fs::read_to_string(extract_path.join("locale/ru.po")).unwrap(),
            "hello"
        );
    }

    #[test]
    fn native_pck_backend_lists_without_extracting_files() {
        let root = create_test_dir("native-list");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"hello".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        let entries = list_pck_entries(pck_path.to_string_lossy().to_string()).unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "locale/ru.po");
        assert_eq!(entries[0].absolute_path, "");
        assert!(!extract_path.exists());
    }

    #[test]
    fn public_extract_pck_paths_writes_only_selected_files_to_destination() {
        let root = create_test_dir("public-extract-paths");
        let pck_path = root.join("game.pck");
        let export_path = root.join("export");

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![
                NativePckWriteEntry {
                    path: "res://locale/ru.po".to_string(),
                    data: PckEntryData::Memory(b"hello".to_vec()),
                    flags: 0,
                },
                NativePckWriteEntry {
                    path: "res://textures/logo.png".to_string(),
                    data: PckEntryData::Memory(b"png".to_vec()),
                    flags: 0,
                },
            ],
        )
        .unwrap();

        let entries = extract_pck_paths(
            pck_path.to_string_lossy().to_string(),
            export_path.to_string_lossy().to_string(),
            vec!["locale".to_string()],
        )
        .unwrap();

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "locale/ru.po");
        assert_eq!(
            fs::read_to_string(export_path.join("locale/ru.po")).unwrap(),
            "hello"
        );
        assert!(!export_path.join("textures/logo.png").exists());
    }

    #[test]
    fn native_pck_backend_rejects_archive_paths_with_parent_traversal() {
        let root = create_test_dir("native-extract-traversal");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://../escape.txt".to_string(),
                data: PckEntryData::Memory(b"nope".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        let result = extract_pck_native(&pck_path, &extract_path);

        assert!(result.is_err());
        assert!(!extract_path.join("escape.txt").exists());
    }

    #[test]
    fn native_pck_backend_rejects_entry_data_past_eof() {
        let root = create_test_dir("native-extract-short-entry");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"hello".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        let len = fs::metadata(&pck_path).unwrap().len();
        File::options()
            .write(true)
            .open(&pck_path)
            .unwrap()
            .set_len(len - 2)
            .unwrap();

        let result = extract_pck_native(&pck_path, &extract_path);

        assert!(result.is_err());
    }

    #[test]
    fn native_pck_backend_rejects_unreasonable_file_count_before_iteration() {
        let root = create_test_dir("native-too-many-files");
        let pck_path = root.join("game.pck");
        write_minimal_pck_header(&pck_path, 1);
        let mut file = File::options().append(true).open(&pck_path).unwrap();
        write_u32(&mut file, 250_001, &pck_path).unwrap();

        let result = load_pck_archive(&pck_path);

        assert!(result.unwrap_err().contains("too many files"));
    }

    #[test]
    fn native_pck_backend_rejects_unreasonable_path_length_before_allocation() {
        let root = create_test_dir("native-path-too-long");
        let pck_path = root.join("game.pck");
        write_minimal_pck_header(&pck_path, 1);
        let mut file = File::options().append(true).open(&pck_path).unwrap();
        write_u32(&mut file, 1, &pck_path).unwrap();
        write_u32(&mut file, 4097, &pck_path).unwrap();

        let result = load_pck_archive(&pck_path);

        assert!(result.unwrap_err().contains("path is too long"));
    }

    #[test]
    fn native_pck_backend_replaces_staged_file() {
        let root = create_test_dir("native-repack");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"new").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"old".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
        )
        .unwrap();
        extract_pck_native(&pck_path, &extract_path).unwrap();

        assert_eq!(
            fs::read_to_string(extract_path.join("locale/ru.po")).unwrap(),
            "new"
        );
    }

    #[test]
    fn repack_with_backup_preserves_original_pck_copy() {
        let root = create_test_dir("native-backup");
        let pck_path = root.join("game.pck");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"new").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"old".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();
        let original = fs::read(&pck_path).unwrap();

        let result = repack_pck_with_options(
            &pck_path,
            &[PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
            true,
        )
        .unwrap();
        let backup_line = result
            .lines()
            .find(|line| line.starts_with("Backup: "))
            .unwrap();
        let backup_path = PathBuf::from(backup_line.trim_start_matches("Backup: "));

        assert_eq!(fs::read(backup_path).unwrap(), original);
    }

    #[test]
    fn public_repack_without_workspace_updates_pck_contents() {
        let root = create_test_dir("public-repack-direct");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"direct").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"old".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        repack_pck(
            pck_path.to_string_lossy().to_string(),
            vec![PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
            None,
            false,
        )
        .unwrap();
        extract_pck_native(&pck_path, &extract_path).unwrap();

        assert_eq!(
            fs::read_to_string(extract_path.join("locale/ru.po")).unwrap(),
            "direct"
        );
    }

    #[test]
    fn write_native_pck_does_not_pad_paths_already_aligned_to_four_bytes() {
        // "res://ab.txt" is exactly 12 bytes (a multiple of 4). Godot stores
        // such a path with NO padding, so the directory's path-length field
        // must equal the byte length, not length + 4.
        let root = create_test_dir("native-path-padding");
        let pck_path = root.join("game.pck");
        let aligned_path = "res://ab.txt";
        assert_eq!(aligned_path.len() % 4, 0);

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: aligned_path.to_string(),
                data: PckEntryData::Memory(b"data".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        // v2 header is 96 bytes; the file count (u32) follows, then the first
        // entry's path-length field.
        let bytes = fs::read(&pck_path).unwrap();
        let path_len = u32::from_le_bytes(bytes[100..104].try_into().unwrap());
        assert_eq!(path_len as usize, aligned_path.len());
    }

    #[test]
    fn repack_streams_large_carried_over_entries_without_corruption() {
        // Carrying an entry over from the source PCK goes through the streaming
        // (Region) path; verify byte-for-byte fidelity past the copy buffer
        // size while a sibling file is replaced.
        let root = create_test_dir("native-stream-large");
        let pck_path = root.join("game.pck");
        let extract_path = root.join("extract");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"new-locale").unwrap();

        let big: Vec<u8> = (0..(256 * 1024 + 7)).map(|i| (i % 251) as u8).collect();
        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![
                NativePckWriteEntry {
                    path: "res://textures/atlas.bin".to_string(),
                    data: PckEntryData::Memory(big.clone()),
                    flags: 0,
                },
                NativePckWriteEntry {
                    path: "res://locale/ru.po".to_string(),
                    data: PckEntryData::Memory(b"old-locale".to_vec()),
                    flags: 0,
                },
            ],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
        )
        .unwrap();
        extract_pck_native(&pck_path, &extract_path).unwrap();

        assert_eq!(
            fs::read(extract_path.join("textures/atlas.bin")).unwrap(),
            big
        );
        assert_eq!(
            fs::read_to_string(extract_path.join("locale/ru.po")).unwrap(),
            "new-locale"
        );
    }

    #[test]
    fn repack_leaves_no_temp_file_behind() {
        let root = create_test_dir("native-no-temp");
        let pck_path = root.join("game.pck");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"new").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![NativePckWriteEntry {
                path: "res://locale/ru.po".to_string(),
                data: PckEntryData::Memory(b"old".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
        )
        .unwrap();

        let leftovers: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            })
            .collect();
        assert!(leftovers.is_empty(), "stray temp files: {:?}", leftovers);
    }

    #[test]
    fn repack_adds_brand_new_file_while_streaming_existing_entries() {
        // Reproduces the reported regression: dropping new files (targets that
        // don't exist in the PCK) must ADD them and the addition must persist
        // and be listed after repack, while existing entries stream through.
        let root = create_test_dir("native-add-new");
        let pck_path = root.join("game.pck");
        let added = root.join("ru.po");
        fs::write(&added, b"translated").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 2,
                major: 4,
                minor: 4,
                patch: 0,
                flags: 0,
            },
            vec![
                NativePckWriteEntry {
                    path: "res://assets/logo.png".to_string(),
                    data: PckEntryData::Memory(b"png-bytes".to_vec()),
                    flags: 0,
                },
                NativePckWriteEntry {
                    path: "res://scenes/main.tscn".to_string(),
                    data: PckEntryData::Memory(b"scene".to_vec()),
                    flags: 0,
                },
            ],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                file: added.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
        )
        .unwrap();

        let listed = list_pck_entries(pck_path.to_string_lossy().to_string()).unwrap();
        let paths: Vec<&str> = listed.iter().map(|entry| entry.path.as_str()).collect();
        assert!(
            paths.contains(&"locale/ru.po"),
            "added file must be present after repack, got {:?}",
            paths
        );
        assert!(paths.contains(&"assets/logo.png"));
        assert!(paths.contains(&"scenes/main.tscn"));
        assert_eq!(listed.len(), 3);
    }

    #[test]
    fn repack_deletes_entry_from_package() {
        let root = create_test_dir("native-delete");
        let pck_path = root.join("game.pck");
        write_native_pck_archive(
            &pck_path,
            NativePckMetadata { format_version: 2, major: 4, minor: 4, patch: 0, flags: 0 },
            vec![
                NativePckWriteEntry { path: "res://keep.txt".into(), data: PckEntryData::Memory(b"keep".to_vec()), flags: 0 },
                NativePckWriteEntry { path: "res://drop.txt".into(), data: PckEntryData::Memory(b"drop".to_vec()), flags: 0 },
            ],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation { kind: "delete".into(), target: "drop.txt".into(), ..Default::default() }],
        )
        .unwrap();

        let paths: Vec<String> = list_pck_entries(pck_path.to_string_lossy().to_string())
            .unwrap()
            .into_iter()
            .map(|entry| entry.path)
            .collect();
        assert_eq!(paths, vec!["keep.txt".to_string()]);
    }

    #[test]
    fn repack_copies_existing_entry_to_new_path() {
        let root = create_test_dir("native-copy");
        let pck_path = root.join("game.pck");
        write_native_pck_archive(
            &pck_path,
            NativePckMetadata { format_version: 2, major: 4, minor: 4, patch: 0, flags: 0 },
            vec![NativePckWriteEntry {
                path: "res://scenarios/case1.gdc".into(),
                data: PckEntryData::Memory(b"scenario-bytes".to_vec()),
                flags: 0,
            }],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                kind: "copy".into(),
                source_path: "scenarios/case1.gdc".into(),
                target: "scenarios/case1 copy.gdc".into(),
                ..Default::default()
            }],
        )
        .unwrap();

        let extract = root.join("out");
        extract_pck_native(&pck_path, &extract).unwrap();
        // Both the original and the duplicate exist with identical bytes.
        assert_eq!(fs::read(extract.join("scenarios/case1.gdc")).unwrap(), b"scenario-bytes");
        assert_eq!(
            fs::read(extract.join("scenarios/case1 copy.gdc")).unwrap(),
            b"scenario-bytes"
        );
    }

    fn create_test_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!(
            "godot-pck-studio-test-{}-{}",
            name,
            timestamp_millis().unwrap()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_minimal_pck_header(path: &Path, format_version: u32) {
        let mut file = File::create(path).unwrap();
        write_u32(&mut file, PCK_HEADER_MAGIC, path).unwrap();
        write_u32(&mut file, format_version, path).unwrap();
        write_u32(&mut file, 4, path).unwrap();
        write_u32(&mut file, 4, path).unwrap();
        write_u32(&mut file, 0, path).unwrap();
        for _ in 0..16 {
            write_u32(&mut file, 0, path).unwrap();
        }
    }

    #[test]
    fn repack_pck_v1_aligns_data_to_16_like_godot3() {
        // Regression: a Godot 3 (PCK format 1) pack must keep its data 16-byte
        // aligned. Writing it unaligned made Godot 3.5 fail to load some
        // resources (blank menu text). Build a v1 pack with odd-length entries,
        // repack, and assert every file's data offset is 16-aligned.
        let root = create_test_dir("native-v1-align");
        let pck_path = root.join("game.pck");
        let replacement = root.join("ru.po");
        fs::write(&replacement, b"translated-locale").unwrap();

        write_native_pck_archive(
            &pck_path,
            NativePckMetadata {
                format_version: 1,
                major: 3,
                minor: 5,
                patch: 2,
                flags: 0,
            },
            vec![
                NativePckWriteEntry {
                    path: "res://.import/a.png-deadbeef.stex".to_string(),
                    data: PckEntryData::Memory(b"odd-length-texture-bytes!".to_vec()),
                    flags: 0,
                },
                NativePckWriteEntry {
                    path: "res://locale/ru.po".to_string(),
                    data: PckEntryData::Memory(b"old".to_vec()),
                    flags: 0,
                },
            ],
        )
        .unwrap();

        repack_pck_native(
            &pck_path,
            &[PckOperation {
                file: replacement.to_string_lossy().to_string(),
                target: "locale/ru.po".to_string(),
                ..Default::default()
            }],
        )
        .unwrap();

        let archive = load_pck_archive(&pck_path).unwrap();
        assert_eq!(archive.metadata.format_version, 1);
        for entry in &archive.entries {
            assert_eq!(
                entry.offset % 16,
                0,
                "v1 entry {} not 16-aligned (offset {})",
                entry.path,
                entry.offset
            );
        }
    }
}






