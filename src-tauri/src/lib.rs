use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    Emitter, Manager,
};

/// Finder 더블클릭으로 cold-start 됐을 때 RunEvent::Opened가 발생하는 시점은
/// WebView가 아직 띄워지지도 않은 단계라, 그때 app.emit("open:file", ...)을
/// 쏘면 listener가 없어 이벤트가 그대로 소실된다. 이 상태에 path를 임시 보관해뒀다가
/// JS bootstrap 끝에서 `webview_ready` 명령으로 한 번에 가져가도록 한다.
#[derive(Default)]
struct PendingOpens(Mutex<Vec<String>>);

/// JS bootstrap이 listener를 다 걸었음을 알리는 플래그.
/// true가 되면 그 후 들어오는 RunEvent::Opened는 stash 대신 emit으로 바로 보냄
/// (warm start에서 같은 path가 두 번 처리되는 걸 막기 위함).
#[derive(Default)]
struct AppReady(AtomicBool);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(PendingOpens::default())
        .manage(AppReady::default())
        .invoke_handler(tauri::generate_handler![
            update_recent_files,
            force_quit,
            webview_ready,
        ])
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

            // macOS cold-start 흰색 flash 차단:
            // WKWebView의 기본 배경은 흰색이라, NSWindow의 backgroundColor(#1C1C1E)를
            // 설정해도 WKWebView가 그 위를 덮어 1프레임이 흰색으로 그려진다.
            // drawsBackground=NO를 KVC로 걸면 WKWebView가 투명해져
            // NSWindow의 배경색이 그대로 비치므로 첫 페인트부터 일관된 다크 톤이 유지된다.
            #[cfg(target_os = "macos")]
            if let Some(window) = app.get_webview_window("main") {
                apply_macos_dark_webview(&window);
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            // macOS Finder에서 .md 파일을 더블클릭하면 RunEvent::Opened 발생.
            // Cold-start(WebView 아직 mount 전)와 warm-start(webview_ready 호출 후) 분기:
            //  - AppReady=false : path를 PendingOpens에 stash. JS가 webview_ready 호출 시 가져감.
            //  - AppReady=true  : emit으로 바로 listener에 전달.
            if let tauri::RunEvent::Opened { urls } = event {
                let ready = app_handle
                    .state::<AppReady>()
                    .0
                    .load(Ordering::SeqCst);
                for url in urls {
                    if let Ok(path) = url.to_file_path() {
                        let path_str = path.to_string_lossy().to_string();
                        if ready {
                            let _ = app_handle.emit("open:file", &path_str);
                        } else {
                            app_handle
                                .state::<PendingOpens>()
                                .0
                                .lock()
                                .unwrap()
                                .push(path_str);
                        }
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

/// JS bootstrap이 끝나 open:file listener가 활성화됐음을 신호하고, 동시에
/// 그 사이 쌓인 cold-start 파일 경로들을 한 번에 가져간다.
/// 호출 후부터는 RunEvent::Opened가 더 이상 stash하지 않고 바로 emit한다.
#[tauri::command]
fn webview_ready(
    pending: tauri::State<PendingOpens>,
    ready: tauri::State<AppReady>,
) -> Vec<String> {
    ready.0.store(true, Ordering::SeqCst);
    let mut p = pending.0.lock().unwrap();
    std::mem::take(&mut *p)
}

/// WKWebView를 투명하게 만들어 NSWindow backgroundColor가 비치게 한다.
///
/// 사용 KVC: `setValue:@NO forKey:@"drawsBackground"`
///   - WKWebView는 `drawsBackground` 프로퍼티를 공식 API로 노출하지 않지만,
///     내부적으로 `setDrawsBackground:`에 대응한다. 이 KVC 트릭은
///     macOS 10.10 (Yosemite, 2014)부터 안정적으로 동작하며 Chrome, Firefox,
///     VS Code, Electron 등 다수의 프로덕션 앱이 동일 방식으로 cold-start
///     흰색 flash를 차단한다.
///
/// 안전성:
///   - WKWebView 포인터가 null이면 즉시 반환 (defensive).
///   - msg_send! 호출은 `unsafe` block 안에서 일어나지만, 매개변수는 모두
///     objc2-foundation의 Retained 객체이므로 lifetime/over-release 위험 없음.
///   - 키 이름은 ASCII 정적 문자열이므로 NSString::from_str이 실패할 수 없다.
///   - 만약 미래 macOS에서 `drawsBackground` KVC가 더 이상 받아들여지지 않더라도
///     기본 동작은 WKWebView가 흰 배경으로 그려지는 것 — flash 보호만 잃을 뿐
///     기능적 회귀는 없다 (즉, fail-open).
///
/// 호출 시점:
///   - setup() 안에서 메인 윈도우가 만들어진 직후. WKWebView가 첫 페인트를
///     수행하기 전이므로 첫 프레임부터 효과가 적용된다.
#[cfg(target_os = "macos")]
fn apply_macos_dark_webview<R: tauri::Runtime>(window: &tauri::WebviewWindow<R>) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    use objc2_foundation::{NSNumber, NSString};

    // with_webview는 closure를 webview thread에서 실행한다. 실패해도 무시
    // (다크 flash가 살짝 보일 뿐 앱 기능에는 영향 없음).
    let _ = window.with_webview(|webview| {
        // PlatformWebview::inner()는 macOS에서 cocoa::base::id (= *mut Object)를 반환.
        // objc2의 AnyObject로 raw pointer 캐스팅한다 (같은 ObjC 객체를 가리킴).
        let wk_ptr: *mut AnyObject = webview.inner() as *mut _;
        if wk_ptr.is_null() {
            return;
        }

        unsafe {
            let key = NSString::from_str("drawsBackground");
            let value = NSNumber::new_bool(false);
            let _: () = msg_send![wk_ptr, setValue: &*value, forKey: &*key];
        }
    });
}
