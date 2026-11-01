#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod audio;
mod client;
mod commands;
mod dns;
mod modifications;
mod patches;
mod runtime;
mod settings;
mod state;
mod web;
use state::AppState;
use tauri::{Emitter,Manager};

fn main(){
 let state=AppState::new().expect("Quinta could not locate its data directories");
 // Read-only inspection for diagnostics and headless UI previews. Never opens a window.
 if std::env::args().any(|a|a=="--print-snapshot") { println!("{}",state.snapshot()); return; }
 if std::env::args().any(|a|a=="--print-runtime") { println!("{}",serde_json::to_string(&runtime::read(&state.paths.runtime_file()).expect("No selected runtime")).unwrap()); return; }
 tauri::Builder::default()
  // A second launch (desktop entry, roblox:// link) focuses the open window instead of opening another.
  .plugin(tauri_plugin_single_instance::init(|app,_args,_cwd|{if let Some(window)=app.get_webview_window("main"){let _=window.unminimize();let _=window.show();let _=window.set_focus();}}))
  .manage(state)
  .invoke_handler(tauri::generate_handler![commands::get_snapshot,commands::save_settings,commands::launch_client,commands::stop_client,commands::update_client,commands::check_client_update,commands::save_runtime,commands::read_logs,commands::save_fast_flags,commands::open_external,commands::open_location,commands::build_shims,commands::window_action,commands::quit_app,commands::client_icon])
  .setup(|app|{
    let state=app.state::<AppState>().inner().clone();let handle=app.handle().clone();
    // Inventory is gathered once, off the UI thread. No idle polling.
    // --launch / --studio start that client as soon as the GPU inventory exists.
    let autostart=std::env::args().find_map(|a|match a.as_str(){"--launch"=>Some("player"),"--studio"=>Some("studio"),_=>None});
    std::thread::spawn(move||{
      *state.gpus.lock().unwrap()=runtime::gpus();let _=handle.emit("hardware-ready",());
      let uri=std::env::args().find(|a|a.starts_with("roblox:")||a.starts_with("roblox-player:"));
      if let Some(kind)=autostart{if let Err(error)=client::launch(state,handle.clone(),kind.into(),uri){eprintln!("Quinta: {error}");}}
    });
    Ok(())
  })
  .on_window_event(|window,event|{if let tauri::WindowEvent::CloseRequested{api,..}=event{let state=window.state::<AppState>();if state.session.lock().unwrap().is_some()||state.busy.load(std::sync::atomic::Ordering::Relaxed){api.prevent_close();let _=window.emit("close-requested",());}}})
  .run(tauri::generate_context!()).expect("Quinta could not start");
}
