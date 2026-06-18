use godot_pck_core::{FileEntry, PckOperation, PckWorkspace};
use std::{path::PathBuf, sync::mpsc::sync_channel};

const EDITOR_WIDTH: f64 = 1220.0;
const EDITOR_HEIGHT: f64 = 780.0;

#[tauri::command]
fn scan_paths(paths: Vec<String>) -> Result<Vec<FileEntry>, String> {
    godot_pck_core::scan_paths(paths)
}

#[tauri::command]
fn repack_pck(
    pck_path: String,
    operations: Vec<PckOperation>,
    workspace_path: Option<String>,
    backup_original: Option<bool>,
) -> Result<String, String> {
    godot_pck_core::repack_pck(
        pck_path,
        operations,
        workspace_path,
        backup_original.unwrap_or(false),
    )
}

#[tauri::command]
fn open_pck_workspace(pck_path: String) -> Result<PckWorkspace, String> {
    godot_pck_core::open_pck_workspace(pck_path)
}

#[tauri::command]
fn cleanup_pck_workspace(workspace_path: String) -> Result<String, String> {
    godot_pck_core::cleanup_pck_workspace(workspace_path)
}

#[tauri::command]
fn open_game_path_dialog(app: tauri::AppHandle) -> Result<Option<String>, String> {
    open_game_path_dialog_impl(app)
}

#[cfg(target_os = "macos")]
fn open_game_path_dialog_impl(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let (sender, receiver) = sync_channel(1);

    app.run_on_main_thread(move || {
        let _ = sender.send(open_game_path_dialog_macos());
    })
    .map_err(|error| format!("Could not open game picker: {}", error))?;

    receiver
        .recv()
        .map_err(|error| format!("Could not read game picker result: {}", error))?
}

#[cfg(not(target_os = "macos"))]
fn open_game_path_dialog_impl(_app: tauri::AppHandle) -> Result<Option<String>, String> {
    Ok(None)
}

#[cfg(target_os = "macos")]
fn open_game_path_dialog_macos() -> Result<Option<String>, String> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSModalResponseOK, NSOpenPanel, NSSavePanel};
    use objc2_foundation::{NSArray, NSString};

    let mtm =
        MainThreadMarker::new().ok_or_else(|| "Game picker must run on main thread".to_string())?;
    let panel = NSOpenPanel::openPanel(mtm);
    let save_panel: &NSSavePanel = &panel;
    let allowed_types =
        NSArray::from_retained_slice(&[NSString::from_str("app"), NSString::from_str("pck")]);

    panel.setCanChooseFiles(true);
    panel.setCanChooseDirectories(false);
    panel.setAllowsMultipleSelection(false);
    panel.setResolvesAliases(true);
    save_panel.setCanCreateDirectories(false);
    save_panel.setAllowsOtherFileTypes(false);
    save_panel.setTitle(Some(&NSString::from_str("Open Godot .app or .pck")));
    save_panel.setMessage(Some(&NSString::from_str(
        "Choose a Godot .app bundle or .pck package",
    )));
    #[allow(deprecated)]
    save_panel.setAllowedFileTypes(Some(&allowed_types));

    if save_panel.runModal() != NSModalResponseOK {
        return Ok(None);
    }

    let path = save_panel
        .URL()
        .and_then(|url| url.path())
        .map(|path| path.to_string())
        .ok_or_else(|| "Game picker did not return a path".to_string())?;
    let path_buf = PathBuf::from(&path);

    if !godot_pck_core::is_game_dialog_selection(&path_buf) {
        return Err(format!(
            "Choose a Godot .app bundle or .pck package: {}",
            path_buf.display()
        ));
    }

    Ok(Some(path))
}

#[tauri::command]
fn open_editor_window(
    app: tauri::AppHandle,
    session_id: String,
    title: String,
) -> Result<(), String> {
    let label = format!(
        "pck-{}-{}",
        godot_pck_core::sanitize_label(&session_id),
        godot_pck_core::timestamp_millis()?
    );
    let url = tauri::WebviewUrl::App(format!("index.html#editor={}", session_id).into());

    tauri::WebviewWindowBuilder::new(&app, label, url)
        .title(title)
        .inner_size(EDITOR_WIDTH, EDITOR_HEIGHT)
        .min_inner_size(920.0, 640.0)
        .focused(true)
        .build()
        .map_err(|error| format!("Could not open PCK editor window: {}", error))?;

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            scan_paths,
            repack_pck,
            open_pck_workspace,
            cleanup_pck_workspace,
            open_editor_window,
            open_game_path_dialog
        ])
        .run(tauri::generate_context!())
        .expect("error while running Godot PCK Studio");
}
