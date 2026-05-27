use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    Emitter,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![update_recent_files, force_quit])
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            let handle = app.handle();
            let menu = build_app_menu(handle, &[])?;
            app.set_menu(menu)?;

            app.on_menu_event(move |app, event| {
                let id = event.id().as_ref().to_string();
                match id.as_str() {
                    "new_file" | "open" | "save" | "save_as" | "export_pdf" | "show_stats" => {
                        let _ = app.emit(&format!("menu:{}", id), ());
                    }
                    other if other.starts_with("recent_") => {
                        let _ = app.emit(&format!("menu:{}", other), ());
                    }
                    _ => {}
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            // macOS Finder에서 .md 파일을 더블클릭하면 RunEvent::Opened 발생.
            // URL을 file path로 변환해 webview에 emit하면 JS가 파일 열기 흐름을 처리합니다.
            if let tauri::RunEvent::Opened { urls } = event {
                for url in urls {
                    if let Ok(path) = url.to_file_path() {
                        let _ = app_handle
                            .emit("open:file", path.to_string_lossy().to_string());
                    }
                }
            }
        });
}

fn recent_label(recent: &[String], i: usize) -> String {
    recent
        .get(i)
        .map(|p| {
            std::path::Path::new(p)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(p.as_str())
                .to_string()
        })
        .unwrap_or_else(|| "(없음)".to_string())
}

fn build_app_menu<R: tauri::Runtime>(
    handle: &tauri::AppHandle<R>,
    recent_files: &[String],
) -> tauri::Result<Menu<R>> {
    // ── App 메뉴 ─────────────────────────────────────────
    let app_menu = Submenu::with_items(
        handle,
        "Mallow",
        true,
        &[
            &PredefinedMenuItem::about(handle, None, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::hide(handle, None)?,
            &PredefinedMenuItem::hide_others(handle, None)?,
            &PredefinedMenuItem::show_all(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::quit(handle, None)?,
        ],
    )?;

    // ── Open Recent 서브메뉴 (5 슬롯) ───────────────────
    let l0 = recent_label(recent_files, 0);
    let l1 = recent_label(recent_files, 1);
    let l2 = recent_label(recent_files, 2);
    let l3 = recent_label(recent_files, 3);
    let l4 = recent_label(recent_files, 4);
    let r0 = MenuItem::with_id(handle, "recent_0", l0.as_str(), recent_files.len() > 0, None::<&str>)?;
    let r1 = MenuItem::with_id(handle, "recent_1", l1.as_str(), recent_files.len() > 1, None::<&str>)?;
    let r2 = MenuItem::with_id(handle, "recent_2", l2.as_str(), recent_files.len() > 2, None::<&str>)?;
    let r3 = MenuItem::with_id(handle, "recent_3", l3.as_str(), recent_files.len() > 3, None::<&str>)?;
    let r4 = MenuItem::with_id(handle, "recent_4", l4.as_str(), recent_files.len() > 4, None::<&str>)?;
    let recent_menu = Submenu::with_items(
        handle,
        "Open Recent",
        true,
        &[&r0, &r1, &r2, &r3, &r4],
    )?;

    // ── File 메뉴 ────────────────────────────────────────
    let file_menu = Submenu::with_items(
        handle,
        "File",
        true,
        &[
            &MenuItem::with_id(handle, "new_file", "New", true, Some("CmdOrCtrl+N"))?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(handle, "open", "Open…", true, Some("CmdOrCtrl+O"))?,
            &recent_menu,
            &MenuItem::with_id(handle, "save", "Save", true, Some("CmdOrCtrl+S"))?,
            &MenuItem::with_id(
                handle,
                "save_as",
                "Save As…",
                true,
                Some("Shift+CmdOrCtrl+S"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(
                handle,
                "export_pdf",
                "Export as PDF…",
                true,
                Some("CmdOrCtrl+E"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::close_window(handle, None)?,
        ],
    )?;

    // ── Edit 메뉴 ────────────────────────────────────────
    let edit_menu = Submenu::with_items(
        handle,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(handle, None)?,
            &PredefinedMenuItem::redo(handle, None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::cut(handle, None)?,
            &PredefinedMenuItem::copy(handle, None)?,
            &PredefinedMenuItem::paste(handle, None)?,
            &PredefinedMenuItem::select_all(handle, None)?,
        ],
    )?;

    // ── View 메뉴 ────────────────────────────────────────
    let view_menu = Submenu::with_items(
        handle,
        "View",
        true,
        &[
            &MenuItem::with_id(
                handle,
                "show_stats",
                "Show Statistics",
                true,
                Some("CmdOrCtrl+Shift+I"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::fullscreen(handle, None)?,
        ],
    )?;

    // ── Window 메뉴 ──────────────────────────────────────
    let window_menu = Submenu::with_items(
        handle,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(handle, None)?,
            &PredefinedMenuItem::maximize(handle, None)?,
        ],
    )?;

    Menu::with_items(
        handle,
        &[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu],
    )
}

#[tauri::command]
fn update_recent_files(app: tauri::AppHandle, paths: Vec<String>) -> Result<(), String> {
    let menu = build_app_menu(&app, &paths).map_err(|e| e.to_string())?;
    app.set_menu(menu).map_err(|e| e.to_string())?;
    Ok(())
}

/// 윈도우 close-request 핸들러가 미저장 confirm을 마친 뒤 호출하는 강제 종료.
/// Tauri v2의 webview window.close()/destroy()가 onCloseRequested 콜백 내부에서
/// 일관되게 동작하지 않아 Rust 측 AppHandle::exit으로 우회한다.
#[tauri::command]
fn force_quit(app: tauri::AppHandle) {
    app.exit(0);
}
