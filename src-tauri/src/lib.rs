use std::collections::HashSet;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Mutex,
};
use tauri::{
    menu::{CheckMenuItemBuilder, Menu, MenuItem, MenuItemKind, PredefinedMenuItem, Submenu},
    Emitter, LogicalPosition, LogicalSize, Manager,
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

/// 창(label) → 현재 열려 있는 문서의 절대 경로 매핑. 같은 파일이 두 창에 동시에 열려
/// 각자 자동 저장하면 cross-window lost update가 나므로(item #5), 새 창을 열기 전에 이
/// 맵으로 "이미 그 경로를 연 다른 창"이 있는지 보고 있으면 그 창을 포커스해 중복 창을
/// 만들지 않는다. 창은 다중 프로세스에 가깝고 cross-window 상태는 Rust가 소유하므로
/// (DirtyWindows와 동일 패턴) 이 맵도 Rust가 권위 있게 보관한다. 프런트엔드는 doc 경로가
/// 바뀔 때마다 set_window_path로 자기 항목을 upsert하고, Destroyed에서 정리한다.
/// (제목 없는 새 문서는 경로가 없어 등록되지 않으므로 절대 dedup되지 않는다.)
#[derive(Default)]
struct WindowPaths(Mutex<std::collections::HashMap<String, String>>);

/// 보기 메뉴의 두 토글(Focus Mode / Typewriter)의 체크마크 상태.
/// macOS 메뉴 막대는 모든 창이 공유하는 단일 객체이고, 메뉴는 최근 파일이 바뀔 때마다
/// build_app_menu로 재생성된다. 이 atomic은 재생성 후에도 체크마크가 유지되도록(빌드 시
/// .checked로 반영) 하고, set_menu_check 명령이 포커스된 창의 실제 상태로 동기화한다.
/// 모드 자체는 창(웹뷰)별이므로 프런트엔드가 진실의 소유자다. (멀티 창 트레이드오프는 README/보고서 참고)
#[derive(Default)]
struct MenuToggles {
    focus_mode: AtomicBool,
    typewriter: AtomicBool,
}

/// 메인 창의 크기·위치(논리 좌표, logical px). 다음 실행에서 같은 자리·크기로 복원해
/// "그냥 기억한다"는 느낌을 준다. recent.json과 동일한 방식(수동 JSON 영속)으로 다루며
/// 새 크레이트/플러그인을 도입하지 않는다. 메인 창에만 적용한다(doc-* 창은 cascade 배치).
///
/// 좌표/크기를 logical px로 저장하는 이유: 모니터마다 scaleFactor가 다르므로 physical px를
/// 그대로 쓰면 다른 배율 디스플레이로 복원할 때 크기가 어긋난다. Tauri의 set_position/
/// set_size에 LogicalPosition/LogicalSize로 넘기면 현재 모니터 배율로 알아서 환산된다.
#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug)]
struct WindowState {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

/// 메인 창 지오메트리의 인메모리 최신값 + 디스크 flush 디바운스용 세대 번호.
/// resize/move는 드래그 중 초당 수십 번 발생하므로 매번 디스크에 쓰지 않는다.
/// 이벤트마다 latest를 갱신 + generation을 증가시키고, 짧게 sleep한 뒤 generation이
/// 그대로면(=그 사이 추가 이동이 없으면) 그때 한 번만 기록한다(트레일링 디바운스).
/// 종료(Destroyed/Exit) 시에는 디바운스를 기다리지 않고 latest를 즉시 flush한다.
#[derive(Default)]
struct WindowGeometry {
    latest: Mutex<Option<WindowState>>,
    generation: AtomicU64,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        // "Copy as Rich Text"가 HTML(+plaintext 폴백)을 클립보드에 쓰기 위함. 네이티브 메뉴에서
        // 호출되므로 웹 navigator.clipboard(사용자 제스처 필요)가 아니라 Rust 측 쓰기를 쓴다.
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(PendingOpens::default())
        .manage(AppReady::default())
        .manage(RecentFiles::default())
        .manage(DirtyWindows::default())
        .manage(WindowPaths::default())
        .manage(MenuToggles::default())
        .manage(WindowGeometry::default())
        .invoke_handler(tauri::generate_handler![
            recent_get,
            recent_add,
            recent_remove,
            set_window_dirty,
            dirty_window_count,
            set_window_path,
            set_window_path_for,
            clear_window_path,
            focus_or_claim_window_for_path,
            quit_app,
            rename_file,
            close_document_window,
            apply_dark_webview,
            webview_ready,
            app_locale,
            set_menu_check,
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
            // 토글은 실행마다 OFF로 시작한다(영속 없음 — no-settings 철학). 따라서 (false, false).
            let menu = build_app_menu(handle, &recents, (false, false))?;
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
                    "new_file" | "open" | "save" | "save_as" | "export_pdf" | "export_html"
                    | "show_stats" | "find" | "copy_rich_text" | "quit" => {
                        send(format!("menu:{}", id));
                    }
                    // Focus Mode / Typewriter 토글: 공유 메뉴의 체크마크를 뒤집고(+ atomic에 보존),
                    // 새 boolean 상태를 포커스된 창에만 전달한다. 프런트엔드는 받은 boolean을
                    // 권위값으로 그대로 적용한다(로컬에서 추측 토글하지 않음). 단일 메뉴 막대를
                    // 모든 창이 공유하므로, 체크마크는 "마지막으로 토글/포커스된 창" 기준이다.
                    "focus_mode" | "typewriter" => {
                        let toggles = app.state::<MenuToggles>();
                        let flag = if id == "focus_mode" {
                            &toggles.focus_mode
                        } else {
                            &toggles.typewriter
                        };
                        // 현재 상태를 반전해 보존하고, 같은 값으로 라이브 메뉴 항목도 갱신한다.
                        let next = !flag.load(Ordering::SeqCst);
                        flag.store(next, Ordering::SeqCst);
                        set_view_check(app, &id, next);
                        match &target {
                            Some(label) => {
                                let _ = app.emit_to(
                                    tauri::EventTarget::webview_window(label.clone()),
                                    &format!("menu:{}", id),
                                    next,
                                );
                            }
                            None => {
                                let _ = app.emit(&format!("menu:{}", id), next);
                            }
                        }
                    }
                    // 최근 파일 목록 비우기. 권위 있는 Rust 목록을 비우고 영속·메뉴 재생성.
                    "recent_clear" => {
                        // state()가 돌려주는 State 가드는 임시값이라, lock 가드를 잡은 채
                        // 같은 문장에서 해제되면 빌림 오류가 난다 → let으로 수명을 늘린다.
                        let recent = app.state::<RecentFiles>();
                        let out = {
                            let mut v = recent.0.lock().unwrap();
                            v.clear();
                            v.clone()
                        };
                        persist_and_sync_recents(app, &out);
                    }
                    // Open Recent 항목 클릭. 메뉴는 인덱스(recent_<N>)로 식별되지만,
                    // 메뉴 빌드 시점과 클릭 시점 사이에 목록이 바뀌면(자동 저장이 맨 앞 파일을
                    // 다시 올리거나 다른 창이 파일을 열어 순서가 변함) 인덱스만 믿으면 "엉뚱한
                    // 파일"이 열린다. 그래서 JS에 인덱스를 넘겨 다시 조회하게 하지 않고,
                    // 여기서 권위 있는 목록(RecentFiles)으로부터 클릭 순간의 실제 PATH를
                    // 즉시 해석해 OS 파일 열기와 동일한 "open:file" 이벤트로 보낸다.
                    // (메뉴는 항상 이 목록으로부터 재빌드되므로 인덱스→경로 매핑이 일관된다.)
                    other if other.starts_with("recent_") => {
                        if let Some(path) = other
                            .strip_prefix("recent_")
                            .and_then(|n| n.parse::<usize>().ok())
                            .and_then(|i| {
                                app.state::<RecentFiles>().0.lock().unwrap().get(i).cloned()
                            })
                        {
                            match &target {
                                Some(label) => {
                                    let _ = app.emit_to(
                                        tauri::EventTarget::webview_window(label.clone()),
                                        "open:file",
                                        path,
                                    );
                                }
                                None => {
                                    let _ = app.emit("open:file", path);
                                }
                            }
                        }
                    }
                    _ => {}
                }
            });

            // ── 세션 복원: 메인 창 크기·위치 ───────────────────────────
            // 지난 실행에서 저장한 지오메트리를 읽어, 첫 페인트 전에 메인 창에 적용한다.
            // 화면 밖(연결 해제된 모니터 등)으로 저장된 창은 보이는 화면 안으로 clamp한다.
            // doc-* 창은 대상이 아니다(main만 복원, 새 창은 cascade 배치).
            if let Some(window) = app.get_webview_window("main") {
                if let Some(saved) = load_window_state(handle) {
                    let geom = clamp_to_visible(&window, saved);
                    // 크기를 먼저, 위치를 나중에 적용한다(일부 플랫폼에서 크기 변경이
                    // 위치를 살짝 움직일 수 있어, 위치를 마지막으로 확정한다).
                    let _ = window.set_size(LogicalSize::new(geom.width, geom.height));
                    let _ = window.set_position(LogicalPosition::new(geom.x, geom.y));
                }
            }

            // macOS cold-start flash 차단:
            // WKWebView의 기본 배경은 흰색이라, NSWindow의 backgroundColor(#1C1C1E)를
            // 설정해도 WKWebView가 그 위를 덮어 1프레임이 흰색으로 그려진다.
            // drawsBackground=NO를 KVC로 걸면 WKWebView가 투명해져
            // NSWindow의 배경색이 그대로 비치므로 첫 페인트부터 일관된 톤이 유지된다.
            // 단, NSWindow backgroundColor는 tauri.conf.json에서 다크(#1C1C1E)로 고정돼 있어
            // 라이트 외관에서는 그 다크색이 1프레임 비쳐 "다크 플래시"가 된다. 그래서 OS 외관을
            // 읽어 라이트면 흰색, 다크면 기존 다크색으로 NSWindow 배경을 첫 페인트 전에 맞춘다.
            // (다크 경로는 #1C1C1E 그대로라 기존 동작과 바이트 동일.)
            #[cfg(target_os = "macos")]
            if let Some(window) = app.get_webview_window("main") {
                apply_macos_window_background(&window);
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
                tauri::RunEvent::WindowEvent { label, event, .. } => {
                    match event {
                        // 메인 창의 이동/크기 변경 → 인메모리 latest 갱신 + 디바운스 디스크 기록.
                        // (doc-* 창은 세션 복원 대상이 아니므로 무시한다.)
                        tauri::WindowEvent::Resized(_) | tauri::WindowEvent::Moved(_)
                            if label == "main" =>
                        {
                            capture_main_geometry(app_handle);
                        }
                        // 마지막 창이 닫히면 앱 종료. "모든 창 닫힘 = 종료" 판단을 Rust에서
                        // 단일하게 처리해, JS가 창 수를 세다 생기는 동시-닫기 race를 제거한다.
                        // (창 닫기 자체는 각 창이 close_document_window로 destroy → 여기서 빈지 확인)
                        tauri::WindowEvent::Destroyed => {
                            // 메인 창이 닫히는 중이면 마지막 지오메트리를 즉시 디스크에 flush한다
                            // (디바운스를 기다리면 종료가 먼저 일어나 유실될 수 있다). Destroyed
                            // 시점엔 창 핸들이 이미 사라졌을 수 있어, 이벤트 직전까지 갱신된
                            // 인메모리 latest를 그대로 기록한다.
                            if label == "main" {
                                flush_main_geometry(app_handle);
                            }
                            // 닫힌 창의 dirty 표시를 정리(누수 방지).
                            app_handle
                                .state::<DirtyWindows>()
                                .0
                                .lock()
                                .unwrap()
                                .remove(&label);
                            // 닫힌 창의 경로 매핑도 정리한다(누수 방지 + 닫힌 창을 가리키는
                            // 잔존 항목으로 focus_or_claim_window_for_path가 오작동하지 않게).
                            app_handle
                                .state::<WindowPaths>()
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
                }
                // ⌘Q 등으로 종료되는 경로(창 Destroyed가 선행하지 않을 수 있음)에서도
                // 마지막 지오메트리를 확실히 남긴다. 인메모리 latest가 있으면 즉시 기록.
                tauri::RunEvent::Exit => {
                    flush_main_geometry(app_handle);
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
    #[serde(rename = "clearRecent")]
    clear_recent: String,
    save: String,
    #[serde(rename = "saveAs")]
    save_as: String,
    #[serde(rename = "exportPdf")]
    export_pdf: String,
    #[serde(rename = "exportHtml")]
    export_html: String,
    #[serde(rename = "showStats")]
    show_stats: String,
    #[serde(rename = "focusMode")]
    focus_mode: String,
    typewriter: String,
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
    find: String,
    #[serde(rename = "copyRichText")]
    copy_rich_text: String,
}

#[derive(serde::Deserialize)]
struct LocaleStrings {
    menu: MenuStrings,
}

/// 기기 OS 언어를 'ko' | 'ja' | 'en'으로 판정한다. 한국어→ko, 일본어→ja, 그 외 en.
/// sys-locale은 CoreFoundation에서 직접 읽으므로 비현지화 앱의 navigator.language
/// 함정을 피한다. 프런트엔드도 app_locale 명령으로 같은 판정을 공유한다.
fn detect_lang() -> &'static str {
    // 세션 동안 한 번만 판정해 캐시한다. 메뉴는 최근 파일이 바뀔 때마다 재빌드되는데,
    // 매번 다시 감지하면 실행 중 OS 언어가 바뀐 경우 메뉴와 프런트엔드(app_locale, 부트스트랩
    // 시점에 고정)가 어긋날 수 있다. OnceLock으로 고정해 세션 내내 한 언어로 일관되게 한다.
    static DETECTED: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();
    *DETECTED.get_or_init(|| match sys_locale::get_locale() {
        Some(l) if l.to_lowercase().starts_with("ko") => "ko",
        Some(l) if l.to_lowercase().starts_with("ja") => "ja",
        _ => "en",
    })
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

/// View 메뉴 안의 CheckMenuItem(focus_mode/typewriter) 체크마크를 갱신한다.
/// Menu::get은 최상위만 훑으므로, stable id "view_menu" 서브메뉴로 내려가 항목을 찾는다.
/// (메뉴가 없거나 항목/종류가 다르면 조용히 무시 — 체크마크는 장식이라 fail-soft)
fn set_view_check<R: tauri::Runtime>(app: &tauri::AppHandle<R>, id: &str, checked: bool) {
    let Some(menu) = app.menu() else { return };
    let Some(MenuItemKind::Submenu(view)) = menu.get("view_menu") else {
        return;
    };
    if let Some(MenuItemKind::Check(item)) = view.get(id) {
        let _ = item.set_checked(checked);
    }
}

/// 프런트엔드가 포커스된 창의 실제 모드 상태로 공유 메뉴 체크마크를 동기화한다.
/// 단일 메뉴 막대를 모든 창이 공유하므로, 창 포커스가 바뀌면 그 창이 이 명령을 호출해
/// 체크마크를 자기 상태에 맞춘다. 보존 atomic도 함께 갱신해 메뉴 재생성 후에도 유지된다.
#[tauri::command]
fn set_menu_check(app: tauri::AppHandle, toggles: tauri::State<MenuToggles>, id: String, checked: bool) {
    match id.as_str() {
        "focus_mode" => toggles.focus_mode.store(checked, Ordering::SeqCst),
        "typewriter" => toggles.typewriter.store(checked, Ordering::SeqCst),
        _ => return, // 알 수 없는 id는 무시
    }
    set_view_check(&app, &id, checked);
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
    // (focus_mode, typewriter) 체크마크 초기 상태. 메뉴 재생성 시 보존된 값을 그대로 반영한다.
    checks: (bool, bool),
) -> tauri::Result<Menu<R>> {
    // 기기 언어의 메뉴 문자열. muda는 predefined 항목 제목을 영문으로 하드코딩하므로
    // (macOS가 자동 현지화해 주지 않는다) About/Hide/Cut/Copy/Close Window 등에도
    // 명시 텍스트를 넘겨 현지화한다. macOS가 Edit 메뉴에 주입하는 시스템 항목
    // (받아쓰기·이모지·쓰기 도구 등)은 Info.plist의 CFBundleLocalizations로 현지화된다.
    // "Mallow"는 브랜드명이라 그대로 둔다.
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
    // 목록 맨 아래에 구분선 + "최근 항목 지우기". 목록이 비어 있으면(=슬롯이 모두 "(없음)")
    // 지울 게 없으므로 비활성화해 빈 상태 처리를 슬롯과 동일하게 맞춘다.
    let clear = MenuItem::with_id(
        handle,
        "recent_clear",
        m.clear_recent.as_str(),
        !recent_files.is_empty(),
        None::<&str>,
    )?;
    let recent_menu = Submenu::with_items(
        handle,
        m.open_recent.as_str(),
        true,
        &[
            &r0,
            &r1,
            &r2,
            &r3,
            &r4,
            &PredefinedMenuItem::separator(handle)?,
            &clear,
        ],
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
            &MenuItem::with_id(
                handle,
                "export_html",
                m.export_html.as_str(),
                true,
                Some("Shift+CmdOrCtrl+E"),
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
            &PredefinedMenuItem::separator(handle)?,
            // 현재 문서를 서식 있는 리치 텍스트(HTML)로 클립보드에 복사 → Slack/메일/Docs/Notion에
            // 붙여넣으면 제목·굵게·목록·표·코드가 그대로 유지된다. plaintext 폴백은 마크다운 원문.
            &MenuItem::with_id(
                handle,
                "copy_rich_text",
                m.copy_rich_text.as_str(),
                true,
                Some("Alt+CmdOrCtrl+C"),
            )?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(handle, "find", m.find.as_str(), true, Some("CmdOrCtrl+F"))?,
        ],
    )?;

    // ── View 메뉴 ────────────────────────────────────────
    // Focus Mode / Typewriter는 체크마크가 붙는 CheckMenuItem이다. 초기 체크 상태는
    // 보존된 토글 상태(checks)에서 읽어 메뉴 재생성(최근 파일 변경) 후에도 유지한다.
    // 서브메뉴에 stable id("view_menu")를 줘서 클릭/동기화 시 항목을 안정적으로 찾는다.
    // ⇧⌘F 사용: ⌃⌘F는 macOS 표준 "전체 화면 전환"(이 View 메뉴의 PredefinedMenuItem::fullscreen
    // 기본 단축키와 동일)과 충돌해 그 시스템 단축키를 가로채므로 피한다. ⌘F=찾기와도 구분된다.
    let focus_item = CheckMenuItemBuilder::with_id("focus_mode", m.focus_mode.as_str())
        .checked(checks.0)
        .accelerator("CmdOrCtrl+Shift+F")
        .build(handle)?;
    let typewriter_item = CheckMenuItemBuilder::with_id("typewriter", m.typewriter.as_str())
        .checked(checks.1)
        .accelerator("CmdOrCtrl+Ctrl+T")
        .build(handle)?;
    let view_menu = Submenu::with_id_and_items(
        handle,
        "view_menu",
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
            &focus_item,
            &typewriter_item,
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

// ── 세션 복원: 메인 창 지오메트리 영속 (recent.json과 동일 방식) ──────────────
fn window_state_file(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("window.json"))
}

/// 저장된 메인 창 지오메트리를 읽는다. 파일이 없거나 파싱 실패면 None(=기본 크기/배치 유지).
fn load_window_state(app: &tauri::AppHandle) -> Option<WindowState> {
    let p = window_state_file(app)?;
    let text = std::fs::read_to_string(&p).ok()?;
    serde_json::from_str::<WindowState>(&text).ok()
}

/// 메인 창 지오메트리를 디스크에 기록한다(영속 실패는 치명적이지 않으므로 조용히 무시).
fn save_window_state(app: &tauri::AppHandle, state: &WindowState) {
    let Some(p) = window_state_file(app) else {
        return;
    };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(state) {
        // 원자적 저장: 임시 파일에 쓴 뒤 rename 한다. 지오메트리 flush는 디바운스
        // 백그라운드 스레드에서 일어나는데, 그 스레드가 write 도중 ⌘Q(process::exit)로
        // 강제 종료되면 std::fs::write는 truncate 후 쓰므로 파일이 반쪽으로 남을 수 있다.
        // 같은 디렉터리 임시 파일 → rename은 원자적이라 절대 찢긴 파일을 남기지 않는다.
        let tmp = p.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

/// 저장된 지오메트리를 "현재 보이는 화면" 안으로 보정한다. 저장 당시 연결돼 있던
/// 모니터가 지금은 빠졌거나(노트북 외부 모니터 분리 등) 해상도가 바뀌어 창이 화면 밖으로
/// 나가는 경우, 사용자가 창을 못 보고 잃어버리는 것을 막는다.
///
/// 전략:
///  1) 창 크기를 가용 모니터들의 최대 표시 영역보다 크지 않게 줄인다(완전히 화면을 덮지 않게).
///  2) 저장된 창의 어느 한 모서리라도 어떤 모니터 영역과 겹치면 그대로 둔다(멀티모니터에서
///     일부만 걸친 정상 배치를 존중). 어떤 모니터와도 겹치지 않으면(=완전히 화면 밖) 1순위
///     모니터 영역 안으로 위치를 끌어와 좌상단이 보이도록 clamp한다.
///
/// 모니터 메트릭은 physical px라, scaleFactor로 logical px로 환산해 저장값(logical)과 맞춘다.
/// (이 버전 Tauri Monitor는 메뉴바/Dock을 제외한 work area를 직접 노출하지 않으므로 전체 모니터
///  사각형을 쓴다. 화면 밖 복구 시 좌상단이 메뉴바에 살짝 걸릴 수 있으나, 오버레이 타이틀바라
///  창을 다시 드래그할 수 있어 수용 가능하다.)
/// 모니터 정보를 못 얻으면(예외) 저장값을 그대로 반환한다(fail-open: 최악의 경우에도 기존 동작).
fn clamp_to_visible<R: tauri::Runtime>(
    window: &tauri::WebviewWindow<R>,
    mut state: WindowState,
) -> WindowState {
    // 비정상(0/음수/NaN) 크기는 무시하고 기본값으로 — 이후 set_size가 무의미해지지 않게.
    if !(state.width.is_finite() && state.height.is_finite()) || state.width < 1.0 || state.height < 1.0
    {
        return state;
    }
    if !(state.x.is_finite() && state.y.is_finite()) {
        return state;
    }

    let Ok(monitors) = window.available_monitors() else {
        return state;
    };
    if monitors.is_empty() {
        return state;
    }

    // 각 모니터의 작업영역을 logical 좌표 사각형으로 변환한다.
    // (Monitor::position/size는 physical px → scale_factor로 나눈다.)
    let rects: Vec<(f64, f64, f64, f64)> = monitors
        .iter()
        .map(|m| {
            let sf = m.scale_factor();
            let pos = m.position();
            let size = m.size();
            let lx = pos.x as f64 / sf;
            let ly = pos.y as f64 / sf;
            let lw = size.width as f64 / sf;
            let lh = size.height as f64 / sf;
            (lx, ly, lw, lh)
        })
        .collect();

    // (1) 크기 clamp: 가장 큰 모니터 작업영역을 넘지 않게 한다.
    let max_w = rects.iter().map(|r| r.2).fold(0.0_f64, f64::max);
    let max_h = rects.iter().map(|r| r.3).fold(0.0_f64, f64::max);
    if max_w > 0.0 {
        state.width = state.width.min(max_w);
    }
    if max_h > 0.0 {
        state.height = state.height.min(max_h);
    }

    // (2) 위치가 어떤 모니터와도 겹치지 않으면 1순위 모니터 안으로 끌어온다.
    let overlaps_any = rects.iter().any(|&(mx, my, mw, mh)| {
        let (wx, wy, ww, wh) = (state.x, state.y, state.width, state.height);
        wx < mx + mw && wx + ww > mx && wy < my + mh && wy + wh > my
    });
    if !overlaps_any {
        let (mx, my, mw, mh) = rects[0];
        // 좌상단이 작업영역 안에 오도록, 그리고 창이 영역을 넘으면 우/하단에 맞춰 당긴다.
        state.x = mx.max((mx + mw - state.width).min(state.x));
        state.y = my.max((my + mh - state.height).min(state.y));
    }

    state
}

/// 메인 창의 현재 지오메트리를 인메모리 latest에 담고, 디바운스 디스크 기록을 예약한다.
/// resize/move 버스트(드래그) 중 매번 디스크에 쓰지 않도록 generation 기반 트레일링
/// 디바운스를 쓴다: 마지막 이벤트로부터 일정 시간 추가 변화가 없을 때 한 번만 기록한다.
fn capture_main_geometry(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    // 최소화/풀스크린 상태의 지오메트리는 복원 기준으로 부적절하므로 저장하지 않는다
    // (다음 실행에서 0 크기/엉뚱한 위치로 복원되는 것을 막는다).
    if window.is_minimized().unwrap_or(false) || window.is_fullscreen().unwrap_or(false) {
        return;
    }
    let Ok(scale) = window.scale_factor() else {
        return;
    };
    let Ok(pos) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.inner_size() else {
        return;
    };
    let state = WindowState {
        x: pos.x as f64 / scale,
        y: pos.y as f64 / scale,
        width: size.width as f64 / scale,
        height: size.height as f64 / scale,
    };

    let geom = app.state::<WindowGeometry>();
    *geom.latest.lock().unwrap() = Some(state);
    // 이 이벤트의 세대 번호를 찍고, sleep 후 그대로면 기록한다(그 사이 추가 이동 없음).
    let my_gen = geom.generation.fetch_add(1, Ordering::SeqCst) + 1;

    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let geom = app.state::<WindowGeometry>();
        // 더 최신 이벤트가 들어왔으면(generation이 바뀜) 그 이벤트의 타이머에 양보한다.
        if geom.generation.load(Ordering::SeqCst) != my_gen {
            return;
        }
        let snapshot = *geom.latest.lock().unwrap();
        if let Some(state) = snapshot {
            save_window_state(&app, &state);
        }
    });
}

/// 종료 경로에서 인메모리 latest를 즉시 디스크에 기록한다(디바운스 대기 없이).
/// latest가 아직 없으면(이번 실행 중 이동/리사이즈가 한 번도 없었으면) no-op.
fn flush_main_geometry(app: &tauri::AppHandle) {
    let snapshot = *app.state::<WindowGeometry>().latest.lock().unwrap();
    if let Some(state) = snapshot {
        save_window_state(app, &state);
    }
}

/// 최근 파일 변경을 디스크에 저장하고 앱 메뉴를 다시 만든다(단일 소스).
/// 메뉴를 재생성하면 체크마크가 초기화되므로, 보존된 토글 상태(MenuToggles)를 읽어
/// 새 메뉴에도 그대로 반영한다(Focus/Typewriter 체크가 최근 파일 변경으로 풀리지 않게).
fn persist_and_sync_recents(app: &tauri::AppHandle, list: &[String]) {
    save_recents(app, list);
    let toggles = app.state::<MenuToggles>();
    let checks = (
        toggles.focus_mode.load(Ordering::SeqCst),
        toggles.typewriter.load(Ordering::SeqCst),
    );
    if let Ok(menu) = build_app_menu(app, list, checks) {
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
    let (out, changed) = {
        let mut v = recent.0.lock().unwrap();
        let before = v.clone();
        v.retain(|p| p != &path);
        v.insert(0, path);
        v.truncate(MAX_RECENT);
        (v.clone(), *v != before)
    };
    // 목록이 그대로면(예: 자동 저장이 이미 맨 앞 파일을 다시 추가) 영속·메뉴 재생성을 생략한다.
    if changed {
        persist_and_sync_recents(&app, &out);
    }
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

// ── 경로별 창 추적 + 중복 창 dedup (item #5) ──────────────────
/// 호출한 창의 현재 문서 경로를 맵에 upsert한다. 프런트엔드는 doc.setPath가 일어나는
/// 모든 경로(파일 열기 성공·저장·다른 이름으로 저장·이름 변경)에서 이 명령을 호출해,
/// 맵이 항상 각 창의 살아 있는 경로를 반영하게 한다. 같은 창이 다른 파일로 바뀌면
/// 옛 경로는 자동으로 덮어써진다(이름 변경 시 옛 경로가 더 이상 이 창을 가리키지 않음).
#[tauri::command]
fn set_window_path(
    window_paths: tauri::State<WindowPaths>,
    window: tauri::WebviewWindow,
    path: String,
) {
    window_paths
        .0
        .lock()
        .unwrap()
        .insert(window.label().to_string(), path);
}

/// 부모가 "곧 띄울 새 창"의 label로 경로를 생성 직후(로드 전에) 등록(claim)한다. 시작 시 파일
/// 열기(startup plan)는 focus_or_claim을 거치지 않으므로, 여기서 등록해야 이후 같은 파일 열기가
/// 그 창으로 dedup된다(item #5). handleOpenPath의 새 창 분기는 focus_or_claim이 같은 label·경로를
/// 이미 claim했으므로, 여기 호출은 동일 값 재등록(멱등)이라 무해하다.
#[tauri::command]
fn set_window_path_for(window_paths: tauri::State<WindowPaths>, label: String, path: String) {
    window_paths.0.lock().unwrap().insert(label, path);
}

/// 경로 등록을 제거한다. label이 주어지면 그 창의 항목을, 없으면 호출 창 자신의 항목을 지운다.
/// 두 가지 롤백에 쓴다: (1) in-place 열기가 실패하면(파일이 막 사라지는 등) 호출 창이 미리 claim한
/// 경로를 지운다(label 생략). (2) 새 창 "생성 자체"가 실패하면 그 새 창 label로 claim해 둔 경로가
/// 영구 잔존해 그 경로를 다시 못 여는 soft-lock이 되므로, 부모가 새 창 label을 주어 지운다.
#[tauri::command]
fn clear_window_path(
    window_paths: tauri::State<WindowPaths>,
    window: tauri::WebviewWindow,
    label: Option<String>,
) {
    let key = label.unwrap_or_else(|| window.label().to_string());
    window_paths.0.lock().unwrap().remove(&key);
}

/// "열기 의도" 시점에 검사와 등록(claim)을 같은 락 안에서 원자적으로 수행한다(item #5).
/// 주어진 경로가 "claim 대상이 아닌 다른 창"에 이미 열려 있으면 그 창을 포커스(필요하면
/// 최소화 해제)하고 true를, 없으면 그 경로를 claim_label로 즉시 등록하고 false를 반환한다.
/// 호출부는 false일 때만 새로 연다(새 창 생성 또는 in-place 로드).
///
/// 왜 원자적이어야 하나(TOCTOU): 예전엔 "검사(focus_window_for_path) → 비동기 로드 → 등록"
/// 순서라, 검사와 등록 사이(파일 로드 시간 + IPC)에 같은 파일을 다시 열면 아직 등록 안 된
/// 창을 못 보고 또 창이 열려, 두 창이 같은 파일을 자동 저장하는 lost update가 생겼다. 또한
/// JS 이벤트 루프는 await 지점마다 끼어들 수 있어, 프런트엔드만으로는 검사-등록을 원자화할 수
/// 없다. 그래서 Rust에서 맵 락을 한 번 잡고 검사+claim을 함께 처리한다.
///
/// claim_label 의미: 이번 열기가 "소유자로 기록할 창"의 label. 새 창 분기에선 곧 만들 새 창의
/// label(미리 생성해 전달), in-place 분기에선 생략 → 호출 창 자신의 label을 쓴다. 검색에서 이
/// label을 제외하므로, 같은 파일을 "현재 창"에서 다시 열 때 자기 자신을 매치해 막는 일이 없다.
/// (반대로 호출 창과 다른 창이 그 경로를 가졌다면 — 예: 비-pristine 창에 이미 열린 파일을 또
///  열 때 — 그 창을 포커스해 중복 창을 deterministic하게 막는다. 예전 self-skip 설계의 허점.)
///
/// 경로 비교: 앱이 절대 경로만 저장하므로 정확히(==) 비교하되, 견고성을 위해 canonicalize를
/// 시도하고 실패하면(파일이 막 이동/삭제되는 등) 원본 문자열로 폴백한다.
#[tauri::command]
fn focus_or_claim_window_for_path(
    app: tauri::AppHandle,
    window_paths: tauri::State<WindowPaths>,
    window: tauri::WebviewWindow,
    path: String,
    claim_label: Option<String>,
) -> bool {
    // 정확 비교 보강: 가능하면 canonical 경로로 맞춰 심볼릭 링크/중복 슬래시 차이를 흡수한다.
    let normalize = |p: &str| {
        std::fs::canonicalize(p)
            .map(|c| c.to_string_lossy().to_string())
            .unwrap_or_else(|_| p.to_string())
    };
    let target = normalize(&path);
    // claim_label 미지정 시 호출 창 자신을 소유자로 삼는다(in-place 재사용).
    let claim = claim_label.unwrap_or_else(|| window.label().to_string());

    // 1) 검사 + claim을 같은 락 안에서 원자적으로 수행한다.
    //    claim 대상이 아닌 창 중 같은 경로를 가진 첫 창을 찾는다. 없으면 즉시 claim한다.
    let found = {
        let mut map = window_paths.0.lock().unwrap();
        let existing = map
            .iter()
            .find(|(label, p)| label.as_str() != claim && normalize(p) == target)
            .map(|(label, _)| label.clone());
        if existing.is_none() {
            map.insert(claim.clone(), path.clone());
        }
        existing
    };

    // 아무도 안 가졌으면 claim 완료 → 호출부가 새로 연다.
    let Some(label) = found else {
        return false;
    };

    // 이미 다른 창이 가졌으면 그 창을 사용자 앞으로 가져온다. 최소화면 먼저 복원한다.
    let Some(target_window) = app.get_webview_window(&label) else {
        // 매핑은 있으나 창 핸들이 없다 — 두 경우다:
        //  (a) 첫 claim 직후 새 창이 아직 "생성되지 않음"(IPC 왕복 사이). 거의 동시에 같은
        //      파일을 두 번 열 때(더블클릭 등) 두 번째 호출이 첫 호출이 막 claim한 label을 본다.
        //  (b) 막 닫혀 Destroyed 정리 "직전"의 잔존 항목.
        // 둘 다 "이미 누군가 그 경로를 여는 중"으로 보고 물러난다(true). 그래야 (a)에서 두 번째
        // 열기가 또 창을 만들지 않아 중복 자동 저장(lost update)을 막는다 — 첫 창이 곧 나타나
        // 그 경로를 소유한다(포커스는 그 시점엔 no-op이지만 의도는 dedup). (b)는 Destroyed가
        // 항목을 곧 지우므로 다시 열면 정상 동작한다(인간 조작 속도에선 사실상 도달 불가).
        // 만약 첫 창 "생성 자체가 실패"하면 openDocumentWindow의 에러 핸들러가 이 잔존 claim을
        // 지워, 그 경로를 영영 못 여는 soft-lock을 막는다.
        return true;
    };
    if target_window.is_minimized().unwrap_or(false) {
        let _ = target_window.unminimize();
    }
    let _ = target_window.set_focus();
    true
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

/// 같은 디렉터리에서 파일을 새 이름으로 이동(rename). 저장된 문서의 파일명을 popover에서
/// 바꿀 때 디스크 파일도 실제로 옮긴다. (Rust std::fs라 fs 스코프 영향 없음)
#[tauri::command]
fn rename_file(old_path: String, new_path: String) -> Result<(), String> {
    use std::path::Path;
    let op = Path::new(&old_path);
    let np = Path::new(&new_path);
    // (1) 같은 폴더 안에서의 rename만 허용 — 경로 분리자/상위 경로(..)로 폴더 밖으로
    //     나가는 이동을 차단한다(프런트의 normalizeFilename 가드에 대한 2차 방어선).
    if np.parent() != op.parent() {
        return Err("invalid".into());
    }
    // (1b) 새 경로의 마지막 구성요소가 "순수 파일명"인지 독립 검증한다(프런트의
    //      normalizeFilename 가드를 Rust 경계에서 한 번 더 — defense-in-depth).
    //      file_name()이 None이면(끝이 "/"이거나 ".."로 끝남) 거부하고, 방어적으로
    //      파일명 구성요소 자체에 경로 분리자가 들어 있으면(예: 분리자가 섞인 비정상
    //      입력) 거부한다. 정상 입력(같은 폴더 + 순수 파일명)에는 영향이 없다.
    match np.file_name().and_then(|n| n.to_str()) {
        Some(name) if !name.contains('/') && !name.contains('\\') => {}
        _ => return Err("invalid".into()),
    }
    // (2) 대상이 이미 존재하면 덮어쓰지 않는다(데이터 손실 방지). 단, 대상이 사실은 원본과
    //     "같은 파일"인 경우(대소문자 비구분 볼륨에서 foo.md → Foo.md 같은 recase)는 허용한다.
    //     canonicalize로 실제 경로를 비교하므로 대소문자 구분/비구분 볼륨 모두에서 정확하다
    //     (단순 lowercase 비교는 대소문자 구분 볼륨에서 "다른 파일"을 같다고 오판할 수 있다).
    //     주: exists 검사와 rename 사이에는 본질적 TOCTOU가 있으나, 단일 사용자 데스크톱
    //     앱에서는 수용 가능한 수준이다.
    if np.exists() {
        let same_file = match (std::fs::canonicalize(op), std::fs::canonicalize(np)) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        };
        if !same_file {
            return Err("exists".into());
        }
    }
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
    {
        // main 창과 동일하게 OS 외관에 맞춰 NSWindow 배경을 먼저 맞춘다(라이트에서 흰색).
        // 이게 없으면 문서 창은 #1C1C1E 고정 배경이라 라이트 OS에서 한 프레임 다크 flash가 보인다.
        // (다크 외관에선 no-op이라 무손상.) 그 다음 webview를 투명화한다.
        apply_macos_window_background(&window);
        apply_macos_dark_webview(&window);
    }
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

/// 라이트 외관 cold-start의 "다크 플래시"를 막기 위해, OS 외관을 읽어 NSWindow의
/// backgroundColor를 첫 페인트 전에 외관에 맞춘다.
///
/// 배경(문제):
///   tauri.conf.json의 window backgroundColor는 #1C1C1E(다크)로 고정돼 있고,
///   apply_macos_dark_webview가 WKWebView를 투명하게 만들어 그 색이 비치게 한다.
///   다크 외관에서는 이게 정확히 의도한 동작(첫 프레임부터 다크)이지만, 라이트
///   외관에서는 흰 webview가 그려지기 직전 1프레임 동안 #1C1C1E(다크)가 보여
///   "다크 플래시"가 된다.
///
/// 해결(보수적·다크 안전):
///   - 다크 외관: 아무것도 하지 않는다 → NSWindow 배경은 conf의 #1C1C1E 그대로.
///     따라서 기존 다크 cold-start 동작과 바이트 동일하다(회귀 없음).
///   - 라이트 외관: NSWindow backgroundColor를 흰색으로 덮는다 → 투명 webview 너머로
///     흰 배경이 비쳐, 첫 프레임부터 흰색이 유지된다(index.html 인라인 스크립트가
///     라이트에서 html 배경을 흰색으로 두는 것과 일관). 다크 플래시가 사라진다.
///   - 외관 판정 실패: 라이트로 단정하지 않고 그대로 둔다(기존 다크 배경 유지) → fail-safe.
///
/// 외관 판정:
///   NSApp.effectiveAppearance의 name이 "Dark"를 포함하는지로 다크/라이트를 가른다.
///   (Apple 권장 방식은 bestMatchFromAppearancesWithNames:지만, name 문자열 검사도
///    동일 결과를 주며 의존성 없이 간결하다. NSAppearanceNameDarkAqua는
///    "NSAppearanceNameDarkAqua"로 끝나 항상 "Dark"를 포함한다.)
///
/// 호출 시점:
///   setup()에서 메인 창 생성 직후, 첫 페인트 전. apply_macos_dark_webview보다 먼저
///   호출해 NSWindow 배경을 먼저 확정한다.
#[cfg(target_os = "macos")]
fn apply_macos_window_background<R: tauri::Runtime>(window: &tauri::WebviewWindow<R>) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send, msg_send_id};
    use objc2::rc::Retained;
    use objc2_foundation::NSString;

    // with_webview closure는 macOS에서 메인(UI) 스레드에서 실행되므로 AppKit 호출이 안전하다
    // (apply_macos_dark_webview와 동일 패턴). 실패해도 무시(fail-safe: 기존 배경 유지).
    let _ = window.with_webview(|webview| {
        let ns_window: *mut AnyObject = webview.ns_window() as *mut _;
        if ns_window.is_null() {
            return;
        }

        unsafe {
            // 1) OS 외관 판정: NSApp.effectiveAppearance.name 에 "Dark"가 들어있으면 다크.
            let app_cls = class!(NSApplication);
            let ns_app: *mut AnyObject = msg_send![app_cls, sharedApplication];
            if ns_app.is_null() {
                return; // 앱 객체를 못 얻으면 그대로 둔다(기존 다크 배경 유지).
            }
            let appearance: *mut AnyObject = msg_send![ns_app, effectiveAppearance];
            if appearance.is_null() {
                return;
            }
            let name: Retained<NSString> = msg_send_id![appearance, name];
            let is_dark = name.to_string().contains("Dark");

            // 2) 다크면 손대지 않는다(기존 #1C1C1E 그대로 → 바이트 동일, 회귀 없음).
            if is_dark {
                return;
            }

            // 3) 라이트면 NSWindow 배경을 흰색으로 덮어 다크 플래시를 제거한다.
            //    +[NSColor whiteColor]는 autoreleased 인스턴스 → 약한 보유로 충분하다
            //    (setBackgroundColor:가 내부에서 retain한다).
            let color_cls = class!(NSColor);
            let white: *mut AnyObject = msg_send![color_cls, whiteColor];
            if white.is_null() {
                return;
            }
            let _: () = msg_send![ns_window, setBackgroundColor: white];
        }
    });
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
