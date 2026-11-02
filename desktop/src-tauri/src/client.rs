use crate::{audio::Audio,dns::DnsService,patches,runtime,state::{AppState,Session}};
use serde_json::{json,Value};
use std::{fs::{self,File,OpenOptions},io::{Read,Write},os::unix::{fs::PermissionsExt,process::CommandExt},path::{Path,Component},process::{Command,Stdio},sync::atomic::Ordering,time::{Duration,Instant},thread};
use tauri::{AppHandle,Emitter,Manager};

fn is_host_graphics(key:&str)->bool{matches!(key,"EGL_PLATFORM"|"DRI_PRIME"|"GALLIUM_DRIVER"|"MESA_LOADER_DRIVER_OVERRIDE"|"__EGL_VENDOR_LIBRARY_FILENAMES"|"__NV_PRIME_RENDER_OFFLOAD"|"__GLX_VENDOR_LIBRARY_NAME"|"__VK_LAYER_NV_optimus"|"MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE"|"VK_ADD_DRIVER_FILES"|"VK_DRIVER_FILES"|"VK_ICD_FILENAMES"|"VK_LOADER_DRIVERS_SELECT"|"VK_LOADER_DRIVERS_DISABLE"|"QUINTA_WAYLAND"|"QUINTA_WAYLAND_HELPER"|"XDG_CONFIG_HOME"|"MACOBLOX_METAL")}
fn progress(app:&AppHandle,label:&str,percent:f64){let _=app.emit("task-progress",json!({"label":label,"percent":percent}));}
fn guest(path:&Path)->String{format!("/Volumes/SystemRoot{}",path.display())}

pub fn launch(state:AppState,app:AppHandle,kind:String,uri:Option<String>)->Result<(),String>{
 if state.busy.swap(true,Ordering::SeqCst){return Err("Another operation is already running".into());}
 let result=launch_inner(&state,&app,&kind,uri);
 state.busy.store(false,Ordering::SeqCst);
 if result.is_ok(){let _=app.emit("session-changed",json!({"running":true}));}
 result
}
fn launch_inner(state:&AppState,app:&AppHandle,kind:&str,uri:Option<String>)->Result<(),String>{
 if state.session.lock().unwrap().is_some(){return Err("A client is already running".into());}
 let runtime=runtime::read(&state.paths.runtime_file())?;let settings=state.settings.lock().unwrap().clone();
 let studio=kind=="studio";
 // Studio's raster Qt backing store uses AppKit's X11 bitmap presentation.
 // Keep the game's selected backend in the saved settings.
 let mut graphics_settings=settings.clone();
 if studio{graphics_settings["display_backend"]=json!("x11");}
 let inventory=state.gpus.lock().unwrap().clone();let graphics=runtime::graphics(&graphics_settings,&inventory,&state.paths.root)?;
 let shim=state.paths.root.join("build");if !shim.join("libQuintaShims.dylib").is_file(){return Err("Native compatibility shims are missing. Run scripts/build-native.sh first.".into());}
 let bundle=if studio{state.paths.root.join("experimental/macos-studio/RobloxStudio.app")}else{state.paths.bundle()};
 let executable=bundle.join(if studio{"Contents/MacOS/RobloxStudio"}else{"Contents/MacOS/RobloxPlayer"});
 if !executable.is_file(){return Err(if studio{"The macOS Studio experiment is not installed"}else{"Install Roblox before launching"}.into());}
 progress(app,"Preparing client",0.15);
 fs::create_dir_all(state.paths.logs()).map_err(|e|e.to_string())?;fs::create_dir_all(&state.paths.cache).map_err(|e|e.to_string())?;
 for path in ["mesa-shader-cache","nvidia-shader-cache","roblox-tmp"]{fs::create_dir_all(state.paths.cache.join(path)).map_err(|e|e.to_string())?;}
 let _=fs::remove_file(state.paths.cache.join("game-closing"));
 let log_path=state.paths.logs().join(format!("launch-{}.log",chrono::Local::now().format("%Y%m%d-%H%M%S")));
 let mut log=OpenOptions::new().create_new(true).append(true).open(&log_path).map_err(|e|e.to_string())?;
 let _=writeln!(log,"Quinta {} · Rust backend\nRuntime: {}\nRenderer: {}\nClient: {}",env!("CARGO_PKG_VERSION"),runtime.executable.display(),settings["renderer"],kind);
 if !studio{
  if settings["auto_patch_throttle"].as_bool().unwrap_or(true){let _=writeln!(log,"Compatibility: {}",patches::throttle(&executable)?);}
  crate::modifications::apply(&state.paths.data,&bundle,&settings)?;
 }
 let pack=bundle.join("Contents/Resources/shaders/shaders_glsl3.pack");if pack.is_file() && std::env::var_os("QUINTA_SKIP_SHADER_REPAIR").is_none(){let _=writeln!(log,"Shaders: {}",patches::shaders(&pack)?);}
 let dns=DnsService::start(settings["dns"].as_str().unwrap_or("quad9"),settings["dns_custom"].as_str().unwrap_or(""))?;
 let audio=Audio::start(&state.paths.cache).unwrap_or(None);
 // Roblox waits on its web view host at startup; without it the window stays black.
 let web=crate::web::WebBridge::start_host(&state.paths.root,studio).or_else(|e|{let _=writeln!(log,"Embedded pages unavailable: {e}");crate::web::WebBridge::start()}).map_err(|e|{let _=writeln!(log,"Web bridge unavailable: {e}");e}).ok();
 let mut variables=graphics;
 variables.extend([
  ("QUINTA_SESSION_DIRECTORY".into(),"Library/Quinta".into()),
  ("QUINTA_MOUSE_SENSITIVITY".into(),settings["mouse_sensitivity"].as_f64().unwrap_or(1.0).to_string()),
  ("QUINTA_SCROLL_SENSITIVITY".into(),settings["scroll_sensitivity"].as_f64().unwrap_or(1.5).to_string()),
  ("QUINTA_DPI_SCALE".into(),settings["dpi_scale"].as_f64().unwrap_or(1.0).to_string()),
  ("QUINTA_KEVENT_POLL_MS".into(),"100".into()),
  ("TMPDIR".into(),guest(&state.paths.cache.join("roblox-tmp"))),
  ("MESA_SHADER_CACHE_DIR".into(),state.paths.cache.join("mesa-shader-cache").display().to_string()),
  ("MESA_GLSL_CACHE_DIR".into(),state.paths.cache.join("mesa-shader-cache").display().to_string()),
  ("QUINTA_PENDING_URI_FILE".into(),guest(&state.paths.cache.join("pending-uri"))),
  ("__GL_SHADER_DISK_CACHE_PATH".into(),state.paths.cache.join("nvidia-shader-cache").display().to_string()),
  ("QUINTA_QUIT_SENTINEL".into(),guest(&state.paths.cache.join("game-closing"))),
  ("QUINTA_RAW_MOUSE".into(),if settings["raw_mouse"].as_bool().unwrap_or(true){"1"}else{"0"}.into()),
 ]);
 // 0 means "Roblox default": never write FramerateCap=0, which Roblox reads as 0 FPS.
 if let Some(cap)=settings["framerate_cap"].as_u64().filter(|c|*c>0){variables.push(("QUINTA_FRAMERATE_CAP".into(),cap.to_string()));}
 if runtime.runtime=="ciderdarling"{variables.push(("QUINTA_NATIVE_WORKQUEUE".into(),"1".into()));}
 if let Some(dns)=&dns{variables.push(("QUINTA_DNS".into(),dns.address.clone()));}
 if let Some(web)=&web{
  variables.push(("QUINTA_WEB_SOCKET".into(),web.guest_path.clone()));
  if let Some(agent)=&web.user_agent{variables.push(("QUINTA_WEB_USER_AGENT".into(),agent.clone()));}
 }
 if let Some(audio)=&audio{variables.extend([("QUINTA_AUDIO".into(),"1".into()),("QUINTA_AUDIO_FIFO".into(),guest(&audio.fifo))]);}else{variables.push(("QUINTA_AUDIO".into(),"0".into()));}
 for (setting,key) in [("trace_gl","QUINTA_TRACE_GL"),("trace_udp","QUINTA_TRACE_UDP"),("diagnostic_signals","QUINTA_DIAGNOSTIC_SIGNALS")]{if settings[setting].as_bool().unwrap_or(false){variables.push((key.into(),"1".into()));}}
 let mut command=Command::new(&runtime.executable);command.env("DPREFIX",&runtime.prefix).stdin(Stdio::null()).stdout(log.try_clone().map_err(|e|e.to_string())?).stderr(log);
 // Host graphics libraries read these before the guest re-exports them.
 for (key,value) in variables.iter().filter(|(k,_)|is_host_graphics(k)){command.env(key,value);}
 // Darling's daemons inherit the environment of whichever launch starts the
 // container. With DISPLAY, iokitd scans XRandR outputs and crashes on
 // Xwayland (no EDID); every IOKit display query then waits forever and
 // Studio hung at startup. The X11 display goes only to the client.
 let wayland=variables.iter().any(|(k,v)|k=="QUINTA_WAYLAND"&&v=="1");
 command.env_remove("DISPLAY").env_remove("XAUTHORITY");
 // Host-backed Xlib consumes host paths, including XAUTHORITY.
 if !wayland{for key in ["DISPLAY","XAUTHORITY"]{if let Ok(value)=std::env::var(key){variables.push((key.into(),value));}}}
 for key in std::env::vars_os().filter_map(|(k,_)|k.to_str().filter(|s|s.starts_with("DSERVER_LOG_")).map(str::to_string)){command.env_remove(key);}
 // Qt logs through os_log, which crashes in Darling: keep Studio on stderr.
 if studio{variables.push(("QT_FORCE_STDERR_LOGGING".into(),"1".into()));}
 if studio{
  let compat=state.paths.root.join("experimental/macos-studio/libStudioCompat.dylib");
  if !compat.is_file(){return Err("The Studio experiment shim must be built before testing this client".into());}
  command.args(["shell","/bin/bash","-c",STUDIO_SCRIPT,"quinta-studio"]).arg(guest(&bundle.join("Contents/MacOS"))).arg(guest(&compat)).arg(guest(&shim));
 }else{
  command.args(["shell","/bin/bash","-c",include_str!("launch.sh"),"quinta"]).arg(guest(&state.paths.data)).arg(guest(&shim)).arg(uri.unwrap_or_default());
 }
 // Darling draws an empty macOS menu bar inside the game window: a black strip on Linux.
 variables.push(("QUINTA_HIDE_MENU_BAR".into(),"1".into()));
 if let Some(hz)=runtime::display_hz(){variables.push(("QUINTA_DISPLAY_HZ".into(),hz.to_string()));}
 // Diagnostics: QUINTA_TRACE_* from the launcher's own environment reach the game.
 for (key,value) in std::env::vars().filter(|(k,_)|k.starts_with("QUINTA_TRACE_")){if !variables.iter().any(|(k,_)|*k==key){variables.push((key,value));}}
 // QUINTA_GUEST_<NAME>=value sets <NAME> inside Darling (e.g. NSZombieEnabled for porting work).
 for (key,value) in std::env::vars(){if let Some(name)=key.strip_prefix("QUINTA_GUEST_").filter(|n|!n.is_empty()){variables.push((name.to_string(),value));}}
 for (key,value) in variables{command.arg(format!("{key}={value}"));}
 command.process_group(0);
 progress(app,"Starting client",0.8);
 let child=command.spawn().map_err(|e|format!("Could not start the selected runtime: {e}"))?;
 *state.last_log.lock().unwrap()=Some(log_path.clone());
 *state.session.lock().unwrap()=Some(Session{child,kind:kind.into(),log:log_path,started:Instant::now(),_dns:dns,_audio:audio,_web:web});
 if settings["hide_launcher_on_launch"].as_bool().unwrap_or(false){if let Some(window)=app.get_webview_window("main"){let _=window.hide();}}
 progress(app,"Client started",1.0);
 let state=state.clone();let app=app.clone();
 thread::spawn(move||loop{
  thread::sleep(Duration::from_millis(750));
  let ended={let mut lock=state.session.lock().unwrap();match lock.as_mut(){None=>return,Some(session)=>match session.child.try_wait(){Ok(Some(status))=>Some((status.success(),session.started.elapsed().as_secs(),session.kind.clone())),Err(_)=>Some((false,0,session.kind.clone())),_=>None}}};
  if let Some((success,seconds,kind))=ended{
   state.session.lock().unwrap().take();if kind=="player"{state.add_playtime(seconds);}
   let _=app.emit("session-changed",json!({"running":false,"success":success,"kind":kind,"earlyExit":seconds<5}));
   if state.settings.lock().unwrap()["show_launcher_after_exit"].as_bool().unwrap_or(true){if let Some(window)=app.get_webview_window("main"){let _=window.show();}}
   return;
  }
 });
 Ok(())
}
const STUDIO_SCRIPT:&str=r#"cd "$1" || exit 1
compat=$2; shim=$3; shift 3
for kv in "$@"; do export "$kv"; done
export DYLD_FORCE_FLAT_NAMESPACE=1 DYLD_INSERT_LIBRARIES="$compat:$shim/libQuintaShims.dylib" DYLD_LIBRARY_PATH="$shim"
exec ./RobloxStudio
"#;

pub fn stop(state:&AppState)->Result<(),String>{let mut lock=state.session.lock().unwrap();if let Some(mut session)=lock.take(){let _=unsafe{libc::kill(-(session.child.id() as i32),libc::SIGTERM)};let _=session.child.kill();let _=session.child.wait();if session.kind=="player"{state.add_playtime(session.started.elapsed().as_secs());}}Ok(())}

pub fn update(state:AppState,app:AppHandle)->Result<Value,String>{
 if state.session.lock().unwrap().is_some(){return Err("Close the client before updating it".into());}
 if state.busy.swap(true,Ordering::SeqCst){return Err("Another operation is already running".into());}
 let result=update_inner(&state,&app);state.busy.store(false,Ordering::SeqCst);result
}
fn update_inner(state:&AppState,app:&AppHandle)->Result<Value,String>{
 progress(app,"Checking Roblox releases",0.01);
 let http=reqwest::blocking::Client::builder().timeout(Duration::from_secs(300)).connect_timeout(Duration::from_secs(10)).user_agent("Quinta/0.1").build().map_err(|e|e.to_string())?;
 let info:Value=http.get("https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer").send().and_then(|r|r.error_for_status()).map_err(|e|e.to_string())?.json().map_err(|e|e.to_string())?;
 let version=info["clientVersionUpload"].as_str().ok_or("Roblox did not provide a deployment version")?;
 if !version.starts_with("version-")||!(16..=64).contains(&version.trim_start_matches("version-").len())||!version.trim_start_matches("version-").chars().all(|c|c.is_ascii_hexdigit()){return Err("Invalid Roblox deployment version".into());}
 let mut response=http.get(format!("https://setup.rbxcdn.com/mac/{version}-RobloxPlayer.zip")).send().and_then(|r|r.error_for_status()).map_err(|e|e.to_string())?;
 let total=response.content_length().unwrap_or(0);if total>2_000_000_000{return Err("Unexpected client archive size".into());}
 let downloads=state.paths.data.join("downloads");fs::create_dir_all(&downloads).map_err(|e|e.to_string())?;
 let mut archive=tempfile::NamedTempFile::new_in(&downloads).map_err(|e|e.to_string())?;let mut buffer=[0u8;65536];let mut received=0u64;let mut last=Instant::now();
 loop{let size=response.read(&mut buffer).map_err(|e|e.to_string())?;if size==0{break;}received+=size as u64;if received>2_000_000_000{return Err("Client archive exceeded the download limit".into());}archive.write_all(&buffer[..size]).map_err(|e|e.to_string())?;if last.elapsed()>Duration::from_millis(120){progress(app,"Downloading Roblox",if total>0{received as f64/total as f64*0.85}else{0.15});last=Instant::now();}}
 progress(app,"Extracting client",0.88);let staging=tempfile::tempdir_in(&downloads).map_err(|e|e.to_string())?;
 let file=File::open(archive.path()).map_err(|e|e.to_string())?;let mut zip=zip::ZipArchive::new(file).map_err(|e|e.to_string())?;
 for i in 0..zip.len(){let mut entry=zip.by_index(i).map_err(|e|e.to_string())?;let relative=entry.enclosed_name().ok_or("Unsafe archive path")?.to_path_buf();if !safe_archive_path(&relative){return Err("Unsafe archive path".into());}let output=staging.path().join(&relative);
  if entry.is_dir(){fs::create_dir_all(&output).map_err(|e|e.to_string())?;continue;}
  fs::create_dir_all(output.parent().unwrap()).map_err(|e|e.to_string())?;
  let mode=entry.unix_mode().unwrap_or(0o644);
  if mode&0o170000==0o120000{let mut target=String::new();entry.read_to_string(&mut target).map_err(|e|e.to_string())?;if Path::new(&target).is_absolute()||!safe_link(&relative,&target){return Err("Unsafe archive symlink".into());}std::os::unix::fs::symlink(target,&output).map_err(|e|e.to_string())?;}else{let mut f=File::create(&output).map_err(|e|e.to_string())?;std::io::copy(&mut entry,&mut f).map_err(|e|e.to_string())?;f.set_permissions(fs::Permissions::from_mode(mode&0o777)).map_err(|e|e.to_string())?;}
 }
 let extracted=staging.path().join("RobloxPlayer.app");if !extracted.join("Contents/MacOS/RobloxPlayer").is_file(){return Err("The archive did not contain a Roblox client".into());}
 let target=state.paths.bundle();let backups=state.paths.data.join("backups");fs::create_dir_all(&backups).map_err(|e|e.to_string())?;let backup=backups.join(format!("RobloxPlayer-{}.app",chrono::Local::now().format("%Y%m%d-%H%M%S")));
 if target.exists(){fs::rename(&target,&backup).map_err(|e|e.to_string())?;}
 if let Err(e)=fs::rename(extracted,&target){if backup.exists(){let _=fs::rename(&backup,&target);}return Err(e.to_string());}
 progress(app,"Roblox updated",1.0);Ok(json!({"version":info["version"],"deployment":version}))
}
fn safe_archive_path(path:&Path)->bool{!path.is_absolute()&&path.components().all(|c|matches!(c,Component::Normal(_)))}
fn safe_link(path:&Path,target:&str)->bool{let mut depth=path.parent().map(|p|p.components().count()).unwrap_or(0);for c in Path::new(target).components(){match c{Component::Normal(_)=>depth+=1,Component::ParentDir=>{if depth==0{return false;}depth-=1;},Component::CurDir=>{},_=>return false}}true}
#[cfg(test)]mod tests{use super::*;#[test]fn archive_paths_and_links_stay_inside_staging(){assert!(safe_archive_path(Path::new("RobloxPlayer.app/Contents/MacOS/RobloxPlayer")));assert!(!safe_archive_path(Path::new("../outside")));assert!(safe_link(Path::new("App/Frameworks/Name"),"Versions/A/Name"));assert!(!safe_link(Path::new("file"),"../outside"));}}
