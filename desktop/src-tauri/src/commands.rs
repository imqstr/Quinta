use crate::{client,runtime,settings,state::{AppState,read_json}};
use serde_json::{json,Value};
use std::{fs,io::{Read,Seek,SeekFrom},process::Command,sync::atomic::Ordering};
use tauri::{AppHandle,Emitter,Manager,State};

#[tauri::command]
pub async fn get_snapshot(state:State<'_,AppState>)->Result<Value,String>{let state=state.inner().clone();tauri::async_runtime::spawn_blocking(move||state.snapshot()).await.map_err(|e|e.to_string())}
#[tauri::command]
pub fn save_settings(state:State<'_,AppState>,patch:Value)->Result<Value,String>{state.patch_settings(&patch)}
#[tauri::command]
pub async fn launch_client(state:State<'_,AppState>,app:AppHandle,kind:Option<String>)->Result<(),String>{let state=state.inner().clone();let uri=state.pending_uri.lock().unwrap().take();let kind=kind.unwrap_or_else(||"player".into());if !matches!(kind.as_str(),"player"|"studio"){return Err("Unknown client".into());}tauri::async_runtime::spawn_blocking(move||client::launch(state,app,kind,uri)).await.map_err(|e|e.to_string())?}
#[tauri::command]
pub async fn stop_client(state:State<'_,AppState>,app:AppHandle,kind:Option<String>)->Result<(),String>{let state=state.inner().clone();let kind=kind.unwrap_or_else(||"player".into());tauri::async_runtime::spawn_blocking(move||{client::stop(&state,&kind)?;let _=app.emit("session-changed",json!({"running":false,"success":true,"kind":kind}));Ok(())}).await.map_err(|e|e.to_string())?}
#[tauri::command]
pub async fn update_client(state:State<'_,AppState>,app:AppHandle)->Result<Value,String>{let state=state.inner().clone();tauri::async_runtime::spawn_blocking(move||client::update(state,app)).await.map_err(|e|e.to_string())?}
#[tauri::command]
pub async fn check_client_update()->Result<Value,String>{tauri::async_runtime::spawn_blocking(||{let client=reqwest::blocking::Client::builder().timeout(std::time::Duration::from_secs(15)).user_agent("Quinta/0.1").build().map_err(|e|e.to_string())?;client.get("https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer").send().and_then(|r|r.error_for_status()).map_err(|e|e.to_string())?.json::<Value>().map_err(|e|e.to_string())}).await.map_err(|e|e.to_string())?}
#[tauri::command]
pub fn save_runtime(state:State<'_,AppState>,selection:runtime::Runtime)->Result<Value,String>{if !state.session.lock().unwrap().is_empty(){return Err("Change runtimes after closing the client".into());}selection.validate()?;let mut stored=read_json(&state.paths.runtime_file());let fields=serde_json::to_value(&selection).map_err(|e|e.to_string())?;if !stored.is_object(){stored=json!({});}stored.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());stored["schema_version"]=json!(1);settings::write_atomic(&state.paths.runtime_file(),&stored)?;Ok(stored)}
#[tauri::command]
pub fn read_logs(state:State<'_,AppState>)->Result<Value,String>{let path=state.last_log.lock().unwrap().clone();let Some(path)=path else{return Ok(json!({"path":null,"text":"No launch logs yet."}));};let mut file=fs::File::open(&path).map_err(|e|e.to_string())?;let size=file.metadata().map_err(|e|e.to_string())?.len();let offset=size.saturating_sub(65_536);file.seek(SeekFrom::Start(offset)).map_err(|e|e.to_string())?;let mut data=Vec::new();file.take(65_536).read_to_end(&mut data).map_err(|e|e.to_string())?;let text=String::from_utf8_lossy(&data);let text=if offset>0{text.split_once('\n').map(|(_,b)|b).unwrap_or(&text)}else{&text};Ok(json!({"path":path,"text":text}))}
#[tauri::command]
pub fn save_fast_flags(state:State<'_,AppState>,flags:Value)->Result<(),String>{if !state.session.lock().unwrap().is_empty(){return Err("Close Roblox before editing its client flags".into());}let fields=flags.as_object().ok_or("Fast flags must be a JSON object")?;if fields.len()>2048||serde_json::to_vec(&flags).map_err(|e|e.to_string())?.len()>262_144{return Err("Too many fast flags".into());}for (key,value)in fields{if key.is_empty()||key.len()>160||!key.chars().all(|c|c.is_ascii_alphanumeric()||c=='_')||!(value.is_string()||value.is_number()||value.is_boolean()){return Err(format!("Invalid fast flag: {key}"));}}settings::write_atomic(&state.paths.bundle().join("Contents/MacOS/ClientSettings/ClientAppSettings.json"),&flags)}
#[tauri::command]
pub fn open_external(url:String)->Result<(),String>{if !url.starts_with("https://")||url.contains(['\n','\r','\0']){return Err("Only HTTPS links can be opened".into());}Command::new("xdg-open").arg(url).spawn().map_err(|e|e.to_string())?;Ok(())}
#[tauri::command]
pub fn open_location(state:State<'_,AppState>,location:String)->Result<(),String>{let path=match location.as_str(){"logs"=>state.paths.logs(),"mods"=>state.paths.data.join("modifications"),"source"=>state.paths.root.clone(),"config"=>state.paths.config.clone(),_=>return Err("Unknown location".into())};fs::create_dir_all(&path).map_err(|e|e.to_string())?;Command::new("xdg-open").arg(path).spawn().map_err(|e|e.to_string())?;Ok(())}
#[tauri::command]
pub async fn build_shims(state:State<'_,AppState>,app:AppHandle)->Result<(),String>{let state=state.inner().clone();if !state.session.lock().unwrap().is_empty(){return Err("Close Roblox before rebuilding the native shims".into());}if state.busy.swap(true,Ordering::SeqCst){return Err("Another operation is running".into());}tauri::async_runtime::spawn_blocking(move||{let result=(||{let runtime=runtime::read(&state.paths.runtime_file())?;let _=app.emit("task-progress",json!({"label":"Building native shims","percent":0.1}));let output=Command::new("bash").arg(state.paths.root.join("scripts/build-native.sh")).env("DARLING_SYSROOT",runtime.sysroot).current_dir(&state.paths.root).output().map_err(|e|e.to_string())?;if !output.status.success(){return Err(String::from_utf8_lossy(&output.stderr).into_owned());}let _=app.emit("task-progress",json!({"label":"Native shims built","percent":1.0}));Ok(())})();state.busy.store(false,Ordering::SeqCst);result}).await.map_err(|e|e.to_string())?}
#[tauri::command]
pub fn window_action(app:AppHandle,action:String)->Result<(),String>{let window=app.get_webview_window("main").ok_or("Main window is unavailable")?;match action.as_str(){"minimize"=>window.minimize(),"maximize"=>window.is_maximized().and_then(|m|if m{window.unmaximize()}else{window.maximize()}),"close"=>window.close(),"drag"=>window.start_dragging(),"show"=>window.show(),_=>return Err("Unknown window action".into())}.map_err(|e|e.to_string())}
#[tauri::command]
pub fn quit_app(state:State<'_,AppState>,app:AppHandle)->Result<(),String>{client::stop(&state,"player")?;client::stop(&state,"studio")?;app.exit(0);Ok(())}

/// The installed client's own app icon (largest PNG inside AppIcon.icns), as a data URL.
#[tauri::command]
pub fn client_icon(state:State<'_,AppState>)->Option<String>{
 let data=fs::read(state.paths.bundle().join("Contents/Resources/AppIcon.icns")).ok()?;
 if data.len()<8||&data[..4]!=b"icns"{return None;}
 let (mut offset,mut best):(usize,Option<&[u8]>)=(8,None);
 while offset+8<=data.len(){
  let length=u32::from_be_bytes(data[offset+4..offset+8].try_into().ok()?) as usize;
  if length<8||offset+length>data.len(){break;}
  let body=&data[offset+8..offset+length];
  if body.starts_with(b"\x89PNG")&&best.is_none_or(|b|b.len()<body.len()){best=Some(body);}
  offset+=length;
 }
 best.map(|png|format!("data:image/png;base64,{}",base64(png)))
}
fn base64(bytes:&[u8])->String{
 const TABLE:&[u8;64]=b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
 let mut out=String::with_capacity(bytes.len().div_ceil(3)*4);
 for chunk in bytes.chunks(3){
  let n=(chunk[0] as u32)<<16|(*chunk.get(1).unwrap_or(&0) as u32)<<8|*chunk.get(2).unwrap_or(&0) as u32;
  for i in 0..4{out.push(if i<=chunk.len(){TABLE[(n>>(18-6*i)&63) as usize] as char}else{'='});}
 }
 out
}
