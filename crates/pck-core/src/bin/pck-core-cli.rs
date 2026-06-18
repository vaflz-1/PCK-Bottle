use serde::Serialize;
use std::{env, process};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PckListingPayload {
    entries: Vec<godot_pck_core::FileEntry>,
    log: String,
}

fn main() {
    let args = env::args().collect::<Vec<_>>();
    let result = match args.get(1).map(String::as_str) {
        Some("list-pck") => list_pck(args.get(2)),
        Some("open-workspace") => open_workspace(args.get(2)),
        Some("extract-paths") => extract_paths(args.get(2), args.get(3)),
        Some("repack") => repack(args.get(2), args.get(3), args.get(4)),
        _ => {
            eprintln!("Usage: pck-core-cli list-pck <path-to.pck>");
            eprintln!("Usage: pck-core-cli open-workspace <path-to.pck>");
            eprintln!("Usage: pck-core-cli extract-paths <path-to.pck> <destination-folder>");
            eprintln!(
                "       pck-core-cli repack <path-to.pck> [workspace-path] <backup:true|false>"
            );
            process::exit(2);
        }
    };

    if let Err(error) = result {
        eprintln!("{}", error);
        process::exit(1);
    }
}

fn list_pck(path: Option<&String>) -> Result<(), String> {
    let path = path.ok_or_else(|| "Missing PCK path".to_string())?;
    let entries = godot_pck_core::list_pck_entries(path.to_string())?;
    let listing = PckListingPayload {
        entries,
        log: format!("Backend: built-in Rust PCK directory reader\nPCK: {}", path),
    };
    serde_json::to_writer(std::io::stdout(), &listing)
        .map_err(|error| format!("Could not encode listing JSON: {}", error))
}

fn open_workspace(path: Option<&String>) -> Result<(), String> {
    let path = path.ok_or_else(|| "Missing PCK path".to_string())?;
    let workspace = godot_pck_core::open_pck_workspace(path.to_string())?;
    serde_json::to_writer(std::io::stdout(), &workspace)
        .map_err(|error| format!("Could not encode workspace JSON: {}", error))
}

fn extract_paths(path: Option<&String>, destination: Option<&String>) -> Result<(), String> {
    let path = path.ok_or_else(|| "Missing PCK path".to_string())?;
    let destination = destination.ok_or_else(|| "Missing extraction destination".to_string())?;
    let selected_paths: Vec<String> = serde_json::from_reader(std::io::stdin())
        .map_err(|error| format!("Could not decode selected PCK paths JSON: {}", error))?;
    let entries = godot_pck_core::extract_pck_paths(
        path.to_string(),
        destination.to_string(),
        selected_paths,
    )?;
    let listing = PckListingPayload {
        entries,
        log: format!(
            "Backend: built-in Rust PCK extractor\nPCK: {}\nDestination: {}",
            path, destination
        ),
    };
    serde_json::to_writer(std::io::stdout(), &listing)
        .map_err(|error| format!("Could not encode extraction JSON: {}", error))
}

fn repack(
    path: Option<&String>,
    second: Option<&String>,
    third: Option<&String>,
) -> Result<(), String> {
    let path = path.ok_or_else(|| "Missing PCK path".to_string())?;
    let (workspace_path, backup_original) = match third {
        Some(backup) => (second.cloned(), backup.as_str() == "true"),
        None => (None, second.map(String::as_str) == Some("true")),
    };
    let operations: Vec<godot_pck_core::PckOperation> =
        serde_json::from_reader(std::io::stdin())
            .map_err(|error| format!("Could not decode staged operations JSON: {}", error))?;
    let log = godot_pck_core::repack_pck(
        path.to_string(),
        operations,
        workspace_path,
        backup_original,
    )?;
    println!("{}", log);
    Ok(())
}
