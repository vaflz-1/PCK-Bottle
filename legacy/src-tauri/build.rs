fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "scan_paths",
            "repack_pck",
            "open_pck_workspace",
            "cleanup_pck_workspace",
            "open_editor_window",
            "open_game_path_dialog",
        ]),
    ))
    .expect("failed to build Tauri app manifest");
}
