use std::collections::HashSet;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    Emitter, Manager,
};

/// 최근 파일 최대 개수 (Open Recent 메뉴 슬롯 수와 일치).
const MAX_RECENT: usize = 5;

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

/// 최근 파일 목록의 단일 소유자(authoritative). 창마다 localStorage로 두면 공유 저장소의
/// read-modify-write가 창 간에 경쟁해 항목이 유실될 수 있어, Rust가 Mutex로 직렬화하고
/// 디스크(JSON)에 영속한다. 메뉴도 이 상태로부터 직접 만든다.
#[derive(Default)]
struct RecentFiles(Mutex<Vec<String>>);

/// 창별 "미저장 변경" 여부 집합. ⌘Q 종료를 원자적으로(부분 종료 없이) 처리하기 위해
/// JS가 doc.isModified 변화를 보고하고, ⌘Q는 이 집합 크기로 통합 확인 여부를 정한다.
#[derive(Default)]
struct DirtyWindows(Mutex<HashSet<String>>);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(PendingOpens::default())
        .manage(AppReady::default())
        .manage(RecentFiles::default())
        .manage(DirtyWindows::default())
        .invoke_handler(tauri::generate_handler![
            recent_get,
            recent_add,
            recent_remove,
            set_window_dirty,
            dirty_window_count,
            quit_app,
            rename_file,
            close_document_window,
            apply_dark_webview,
            webview_ready,
            app_locale,
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
            // 영속된 최근 파일을 읽어 상태와 메뉴에 반영한다.
            let recents = load_recents(handle);
            *app.state::<RecentFiles>().0.lock().unwrap() = recents.clone();
            let menu = build_app_menu(handle, &recents)?;
            app.set_menu(menu)?;

            app.on_menu_event(move |app, event| {
                let id = event.id().as_ref().to_string();
                // 멀티 창: 메뉴 명령은 "현재 포커스된 창"만 처리해야 한다.
                // app.emit은 모든 창에 broadcast되어 여러 창이 동시에 반응하므로,
                // 포커스 창(없으면 첫 창)에만 emit_to로 전달한다.
                let target = focused_or_any_label(app);
                let send = |ev: String| {
                    match &target {
                        Some(label) => {
                            let _ = app.emit_to(
                                tauri::EventTarget::webview_window(label.clone()),
                                &ev,
                                (),
                            );
                        }
                        None => {
                            let _ = app.emit(&ev, ());
                        }
                    }
                };
                match id.as_str() {
                    // quit 포함 모든 명령을 "포커스된 창"에만 전달한다.
                    // ⌘Q는 포커스 창이 코디네이터가 되어 dirty_window_count로 전체 미저장
                    // 개수를 조회 → 통합 확인 1회 → quit_app(전체 종료) 또는 취소(아무것도 안 함).
                    // 이로써 "일부 창만 닫히는" 부분 종료가 발생하지 않는다(원자적 종료).
                    "new_file" | "open" | "save" | "save_as" | "export_pdf" | "show_stats"
                    | "quit" => {
                        send(format!("menu:{}", id));
                    }
                    other if other.starts_with("recent_") => {
                        send(format!("menu:{}", other));
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
            match event {
                // macOS Finder에서 .md 파일을 더블클릭하면 RunEvent::Opened 발생.
                // Cold-start(WebView 아직 mount 전)와 warm-start(webview_ready 호출 후) 분기:
                //  - AppReady=false : path를 PendingOpens에 stash. JS가 webview_ready 호출 시 가져감.
                //  - AppReady=true  : emit으로 바로 listener에 전달.
                tauri::RunEvent::Opened { urls } => {
                    let ready = app_handle.state::<AppReady>().0.load(Ordering::SeqCst);
                    for url in urls {
                        if let Ok(path) = url.to_file_path() {
                            let path_str = path.to_string_lossy().to_string();
                            if ready {
                                // warm start: 포커스된 창 한 곳에만 전달 → 그 창이 새 문서 창을 연다.
                                // (broadcast하면 모든 창이 같은 파일로 새 창을 만들어 중복된다.)
                                if let Some(label) = focused_or_any_label(app_handle) {
                                    let _ = app_handle.emit_to(
                                        tauri::EventTarget::webview_window(label),
                                        "open:file",
                                        path_str,
                                    );
                                }
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
                // 마지막 창이 닫히면 앱 종료. "모든 창 닫힘 = 종료" 판단을 Rust에서
                // 단일하게 처리해, JS가 창 수를 세다 생기는 동시-닫기 race를 제거한다.
                // (창 닫기 자체는 각 창이 close_document_window로 destroy → 여기서 빈지 확인)
                tauri::RunEvent::WindowEvent {
                    label,
                    event: tauri::WindowEvent::Destroyed,
                    ..
                } => {
                    // 닫힌 창의 dirty 표시를 정리(누수 방지).
                    app_handle
                        .state::<DirtyWindows>()
                        .0
                        .lock()
                        .unwrap()
                        .remove(&label);
                    if app_handle.webview_windows().is_empty() {
                        app_handle.exit(0);
                    }
                }
                _ => {}
            }
        });
}

/// 멀티 창 라우팅용: 현재 포커스된 창의 label, 없으면 아무 창의 label.
/// 메뉴 명령·OS 파일 열기를 정확히 한 창에만 전달하기 위해 사용한다.
/// (get_focused_window는 unstable feature라, 안정 API인 webview_windows + is_focused로 구현)
fn focused_or_any_label<R: tauri::Runtime>(app: &tauri::AppHandle<R>) -> Option<String> {
    let windows = app.webview_windows();
    for (label, w) in &windows {
        if w.is_focused().unwrap_or(false) {
            return Some(label.clone());
        }
    }
    windows.keys().next().cloned()
}

// ── i18n: 네이티브 메뉴 현지화 ────────────────────────────────
// 언어 파일은 프런트엔드(src/i18n/locales)와 "동일한 JSON"을 단일 소스로 쓴다.
// Rust는 빌드시 그 파일을 include_str!로 임베드하고 menu 섹션만 파싱해 메뉴를 만든다.
const EN_JSON: &str = include_str!("../../src/i18n/locales/en.json");
const KO_JSON: &str = include_str!("../../src/i18n/locales/ko.json");
const JA_JSON: &str = include_str!("../../src/i18n/locales/ja.json");

/// 언어 파일의 menu 섹션. 프런트엔드 JSON의 camelCase 키를 serde rename으로 매핑한다.
#[derive(serde::Deserialize)]
struct MenuStrings {
    file: String,
    edit: String,
    view: String,
    window: String,
    new: String,
    open: String,
    #[serde(rename = "openRecent")]
    open_recent: String,
    #[serde(rename = "recentEmpty")]
    recent_empty: String,
    save: String,
    #[serde(rename = "saveAs")]
    save_as: String,
    #[serde(rename = "exportPdf")]
    export_pdf: String,
    #[serde(rename = "showStats")]
    show_stats: String,
    quit: String,
    // predefined 항목 — muda가 영문 하드코딩한 제목을 명시 텍스트로 덮어쓴다.
    about: String,
    hide: String,
    #[serde(rename = "hideOthers")]
    hide_others: String,
    #[serde(rename = "showAll")]
    show_all: String,
    undo: String,
    redo: String,
    cut: String,
    copy: String,
    paste: String,
    #[serde(rename = "selectAll")]
    select_all: String,
    minimize: String,
    zoom: String,
    fullscreen: String,
    #[serde(rename = "closeWindow")]
    close_window: String,
}

#[derive(serde::Deserialize)]
struct LocaleStrings {
    menu: MenuStrings,
}

/// 기기 OS 언어를 'ko' | 'en'으로 판정한다. 한국어로 시작하면 ko, 그 외에는 모두 en.
/// sys-locale은 CoreFoundation에서 직접 읽으므로 비현지화 앱의 navigator.language
/// 함정을 피한다. 프런트엔드도 app_locale 명령으로 같은 판정을 공유한다.
fn detect_lang() -> &'static str {
    match sys_locale::get_locale() {
        Some(l) if l.to_lowercase().starts_with("ko") => "ko",
        Some(l) if l.to_lowercase().starts_with("ja") => "ja",
        _ => "en",
    }
}

/// 감지된 언어의 메뉴 문자열을 돌려준다. 파싱 실패 시 en으로 폴백한다.
fn menu_strings(lang: &str) -> MenuStrings {
    let raw = match lang {
        "ko" => KO_JSON,
        "ja" => JA_JSON,
        _ => EN_JSON,
    };
    serde_json::from_str::<LocaleStrings>(raw)
        .or_else(|_| serde_json::from_str::<LocaleStrings>(EN_JSON))
        .expect("en.json must contain a valid menu section")
        .menu
}

/// 프런트엔드가 기기 언어를 알아내 i18n을 동기화하기 위한 명령(메뉴와 동일 판정).
#[tauri::command]
fn app_locale() -> &'static str {
    detect_lang()
}

fn recent_label(recent: &[String], i: usize, empty: &str) -> String {
    recent
        .get(i)
        .map(|p| {
            std::path::Path::new(p)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(p.as_str())
                .to_string()
        })
        .unwrap_or_else(|| empty.to_string())
}

fn build_app_menu<R: tauri::Runtime>(
    handle: &tauri::AppHandle<R>,
    recent_files: &[String],
) -> tauri::Result<Menu<R>> {
    // 기기 언어의 메뉴 문자열. (predefined 항목은 macOS가 시스템 언어로 자동 현지화하므로
    //  여기서 다루는 건 커스텀 항목/서브메뉴 제목뿐이다. "Mallow"는 브랜드명이라 그대로 둔다.)
    let m = menu_strings(detect_lang());

    // ── App 메뉴 ─────────────────────────────────────────
    let app_menu = Submenu::with_items(
        handle,
        "Mallow",
        true,
        &[
            &PredefinedMenuItem::about(handle, Some(m.about.as_str()), None)?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::hide(handle, Some(m.hide.as_str()))?,
            &PredefinedMenuItem::hide_others(handle, Some(m.hide_others.as_str()))?,
            &PredefinedMenuItem::show_all(handle, Some(m.show_all.as_str()))?,
            &PredefinedMenuItem::separator(handle)?,
            // 종료 전 각 창의 미저장 변경을 확인하기 위해 predefined quit 대신
            // 커스텀 항목을 쓴다. "menu:quit"를 전 창에 broadcast → 각 창이 스스로
            // 확인 후 닫히고, 마지막 창이 닫히면 RunEvent에서 exit한다.
            &MenuItem::with_id(handle, "quit", m.quit.as_str(), true, Some("CmdOrCtrl+Q"))?,
        ],
    )?;

    // ── Open Recent 서브메뉴 (5 슬롯) ───────────────────
    let l0 = recent_label(recent_files, 0, m.recent_empty.as_str());
    let l1 = recent_label(recent_files, 1, m.recent_empty.as_str());
    let l2 = recent_label(recent_files, 2, m.recent_empty.as_str());
    let l3 = recent_label(recent_files, 3, m.recent_empty.as_str());
    let l4 = recent_label(recent_files, 4, m.recent_empty.as_str());
    let r0 = MenuItem::with_id(handle, "recent_0", l0.as_str(), recent_files.len() > 0, None::<&str>)?;
    let r1 = MenuItem::with_id(handle, "recent_1", l1.as_str(), recent_files.len() > 1, None::<&str>)?;
    let r2 = MenuItem::with_id(handle, "recent_2", l2.as_str(), recent_files.len() > 2, None::<&str>)?;
    let r3 = MenuItem::with_id(handle, "recent_3", l3.as_str(), recent_files.len() > 3, None::<&str>)?;
    let r4 = MenuItem::with_id(handle, "recent_4", l4.as_str(), recent_files.len() > 4, None::<&str>)?;
    let recent_menu = Submenu::with_items(
        handle,
        m.open_recent.as_str(),
        true,
        &[&r0, &r1, &r2, &r3, &r4],
    )?;

    // ── File 메뉴 ────────────────────────────────────────
    let file_menu = Submenu::with_items(
        handle,
        m.file.as_str(),
        true,
        &[
            &MenuItem::with_id(handle, "new_file", m.new.as_str(), true, Some("CmdOrCtrl+N"))?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(handle, "open", m.open.as_str(), true, Some("CmdOrCtrl+O"))?,
            &recent_menu,
            &MenuItem::with_id(handle, "save", m.save.as_str(), true, Some("CmdOrCtrl+S"))?,
            &MenuItem::with_id(
                handle,
                "save_as",
                m.save_as.as_str(),
                true,
                Some("Shift+CmdOrCtrl+S"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(
                handle,
                "export_pdf",
                m.export_pdf.as_str(),
                true,
                Some("CmdOrCtrl+E"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::close_window(handle, Some(m.close_window.as_str()))?,
        ],
    )?;

    // ── Edit 메뉴 ────────────────────────────────────────
    let edit_menu = Submenu::with_items(
        handle,
        m.edit.as_str(),
        true,
        &[
            &PredefinedMenuItem::undo(handle, Some(m.undo.as_str()))?,
            &PredefinedMenuItem::redo(handle, Some(m.redo.as_str()))?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::cut(handle, Some(m.cut.as_str()))?,
            &PredefinedMenuItem::copy(handle, Some(m.copy.as_str()))?,
            &PredefinedMenuItem::paste(handle, Some(m.paste.as_str()))?,
            &PredefinedMenuItem::select_all(handle, Some(m.select_all.as_str()))?,
        ],
    )?;

    // ── View 메뉴 ────────────────────────────────────────
    let view_menu = Submenu::with_items(
        handle,
        m.view.as_str(),
        true,
        &[
            &MenuItem::with_id(
                handle,
                "show_stats",
                m.show_stats.as_str(),
                true,
                Some("CmdOrCtrl+Shift+I"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &PredefinedMenuItem::fullscreen(handle, Some(m.fullscreen.as_str()))?,
        ],
    )?;

    // ── Window 메뉴 ──────────────────────────────────────
    let window_menu = Submenu::with_items(
        handle,
        m.window.as_str(),
        true,
        &[
            &PredefinedMenuItem::minimize(handle, Some(m.minimize.as_str()))?,
            &PredefinedMenuItem::maximize(handle, Some(m.zoom.as_str()))?,
        ],
    )?;

    Menu::with_items(
        handle,
        &[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu],
    )
}

// ── 최근 파일: Rust 단일 소유 + 디스크 영속 ──────────────────
fn recents_file(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("recent.json"))
}

fn load_recents(app: &tauri::AppHandle) -> Vec<String> {
    let Some(p) = recents_file(app) else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(&p) else {
        return Vec::new();
    };
    serde_json::from_str::<Vec<String>>(&text)
        .unwrap_or_default()
        .into_iter()
        .take(MAX_RECENT)
        .collect()
}

fn save_recents(app: &tauri::AppHandle, list: &[String]) {
    let Some(p) = recents_file(app) else {
        return;
    };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(list) {
        let _ = std::fs::write(&p, text);
    }
}

/// 최근 파일 변경을 디스크에 저장하고 앱 메뉴를 다시 만든다(단일 소스).
fn persist_and_sync_recents(app: &tauri::AppHandle, list: &[String]) {
    save_recents(app, list);
    if let Ok(menu) = build_app_menu(app, list) {
        let _ = app.set_menu(menu);
    }
}

#[tauri::command]
fn recent_get(recent: tauri::State<RecentFiles>) -> Vec<String> {
    recent.0.lock().unwrap().clone()
}

#[tauri::command]
fn recent_add(
    app: tauri::AppHandle,
    recent: tauri::State<RecentFiles>,
    path: String,
) -> Vec<String> {
    let out = {
        let mut v = recent.0.lock().unwrap();
        v.retain(|p| p != &path);
        v.insert(0, path);
        v.truncate(MAX_RECENT);
        v.clone()
    };
    persist_and_sync_recents(&app, &out);
    out
}

#[tauri::command]
fn recent_remove(
    app: tauri::AppHandle,
    recent: tauri::State<RecentFiles>,
    path: String,
) -> Vec<String> {
    let out = {
        let mut v = recent.0.lock().unwrap();
        v.retain(|p| p != &path);
        v.clone()
    };
    persist_and_sync_recents(&app, &out);
    out
}

// ── 창별 dirty 추적 + 원자적 종료 ─────────────────────────────
#[tauri::command]
fn set_window_dirty(
    dirty_windows: tauri::State<DirtyWindows>,
    window: tauri::WebviewWindow,
    dirty: bool,
) {
    let mut s = dirty_windows.0.lock().unwrap();
    if dirty {
        s.insert(window.label().to_string());
    } else {
        s.remove(window.label());
    }
}

#[tauri::command]
fn dirty_window_count(dirty_windows: tauri::State<DirtyWindows>) -> usize {
    dirty_windows.0.lock().unwrap().len()
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

/// 같은 디렉터리에서 파일을 새 이름으로 이동(rename). 저장된 문서의 파일명을 popover에서
/// 바꿀 때 디스크 파일도 실제로 옮긴다. (Rust std::fs라 fs 스코프 영향 없음)
#[tauri::command]
fn rename_file(old_path: String, new_path: String) -> Result<(), String> {
    std::fs::rename(&old_path, &new_path).map_err(|e| e.to_string())
}

/// 현재 창만 닫는다(destroy). 마지막 창이면 RunEvent::WindowEvent::Destroyed에서
/// webview_windows가 빈 것을 확인하고 app.exit(0)으로 앱을 종료한다.
/// Tauri v2 macOS에서 JS window.close()/destroy()가 onCloseRequested 콜백 내부에서
/// 일관되게 동작하지 않는 이슈가 있어, Rust 측에서 호출 창을 destroy한다.
/// destroy는 close와 달리 CloseRequested를 다시 발생시키지 않아 재진입이 없다.
#[tauri::command]
fn close_document_window(window: tauri::WebviewWindow) {
    let _ = window.destroy();
}

/// JS에서 생성된 문서 창에도 main 창과 동일한 다크 webview 처리를 적용한다.
/// (setup()은 main 창에만 적용하므로, 새 창은 bootstrap에서 이 커맨드를 호출한다.)
#[tauri::command]
fn apply_dark_webview(window: tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    apply_macos_dark_webview(&window);
    #[cfg(not(target_os = "macos"))]
    let _ = window;
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
