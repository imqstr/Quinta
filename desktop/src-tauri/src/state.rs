use crate::{audio::Audio,dns::DnsService,runtime::{self,Gpu},settings};
use serde_json::{json,Value};
use std::{fs,path::{Path,PathBuf},process::Child,sync::{Arc,Mutex,atomic::AtomicBool},time::Instant};

#[derive(Clone)]
pub struct Paths{pub root:PathBuf,pub data:PathBuf,pub config:PathBuf,pub cache:PathBuf}
impl Paths{
 pub fn discover()->Result<Self,String>{
    let home=std::env::var_os("HOME").map(PathBuf::from).ok_or("HOME is unavailable")?;
    let root=std::env::var_os("QUINTA_ROOT").map(PathBuf::from).unwrap_or_else(||PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));
    let root=root.canonicalize().map_err(|e|format!("Cannot locate Quinta sources: {e}"))?;
    let config=std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(||home.join(".config")).join("quinta");
    let cache=std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(||home.join(".cache")).join("quinta");
    let data=if root.join(".git").is_dir()||root.join("RobloxPlayer.app").is_dir(){root.clone()}else{std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(||home.join(".local/share")).join("quinta")};
    Ok(Self{root,data,config,cache})
 }
 pub fn bundle(&self)->PathBuf{self.data.join("RobloxPlayer.app")}
 pub fn settings_file(&self)->PathBuf{self.config.join("settings.json")}
 pub fn runtime_file(&self)->PathBuf{self.config.join("runtime.json")}
 pub fn logs(&self)->PathBuf{self.data.join("logs")}
}

pub struct Session{pub child:Child,pub kind:String,pub log:PathBuf,pub started:Instant,pub _dns:Option<DnsService>,pub _audio:Option<Audio>,pub _web:Option<crate::web::WebBridge>}
impl Drop for Session{fn drop(&mut self){if self.child.try_wait().ok().flatten().is_none(){let _=self.child.kill();let _=self.child.wait();}}}
#[derive(Clone)]
pub struct AppState{
 pub paths:Paths,pub settings:Arc<Mutex<Value>>,pub session:Arc<Mutex<Option<Session>>>,
 pub gpus:Arc<Mutex<Vec<Gpu>>>,pub busy:Arc<AtomicBool>,pub last_log:Arc<Mutex<Option<PathBuf>>>,pub pending_uri:Arc<Mutex<Option<String>>>,
}
impl AppState{
 pub fn new()->Result<Self,String>{let paths=Paths::discover()?;let stored=settings::load(&paths.settings_file());let last_log=latest_log(&paths.logs());
    Ok(Self{paths,settings:Arc::new(Mutex::new(stored)),session:Arc::new(Mutex::new(None)),gpus:Arc::new(Mutex::new(Vec::new())),busy:Arc::new(AtomicBool::new(false)),last_log:Arc::new(Mutex::new(last_log)),pending_uri:Arc::new(Mutex::new(None))})
 }
 pub fn snapshot(&self)->Value{
    let settings=self.settings.lock().unwrap().clone();let runtime=runtime::read(&self.paths.runtime_file());
    let version=client_version(&self.paths.bundle());let shims=self.paths.root.join("build/libQuintaShims.dylib").is_file();
    let session=self.session.lock().unwrap();let running=session.as_ref().map(|s|json!({"kind":s.kind,"pid":s.child.id(),"seconds":s.started.elapsed().as_secs(),"log":s.log}));
    let problem=if runtime.is_err(){runtime.as_ref().err().cloned()}else if version.is_none(){Some("Install the Roblox client to get started".into())}else if !shims{Some("Build the native compatibility shims first".into())}else{None};
    json!({"version":env!("CARGO_PKG_VERSION"),"clientVersion":version,"settings":settings,"runtime":runtime.as_ref().ok(),"runtimeError":runtime.as_ref().err(),
      "gpus":self.gpus.lock().unwrap().clone(),"session":running,"busy":self.busy.load(std::sync::atomic::Ordering::Relaxed),"canLaunch":problem.is_none(),"readiness":problem,
      "source":self.paths.root,"data":self.paths.data,"logs":self.paths.logs(),"shimsReady":shims,"backend":"Rust","studioInstalled":self.paths.root.join("experimental/macos-studio/RobloxStudio.app/Contents/MacOS/RobloxStudio").is_file(),
      "mods":crate::modifications::list(&self.paths.data,&settings),"fastFlags":read_json(&self.paths.bundle().join("Contents/MacOS/ClientSettings/ClientAppSettings.json"))})
 }
 pub fn patch_settings(&self,patch:&Value)->Result<Value,String>{settings::validate_patch(patch)?;let mut lock=self.settings.lock().unwrap();let mut updated=lock.clone();updated.as_object_mut().ok_or("Invalid stored settings")?.extend(patch.as_object().unwrap().clone());settings::write_atomic(&self.paths.settings_file(),&updated)?;*lock=updated.clone();Ok(updated)}
 pub fn add_playtime(&self,seconds:u64){let mut lock=self.settings.lock().unwrap();let old=lock["playtime_seconds"].as_u64().unwrap_or(0);lock["playtime_seconds"]=json!(old+seconds);let _=settings::write_atomic(&self.paths.settings_file(),&lock);}
}
pub fn client_version(bundle:&Path)->Option<String>{let value=plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;value.as_dictionary()?.get("CFBundleShortVersionString")?.as_string().map(str::to_string)}
pub fn read_json(path:&Path)->Value{fs::read(path).ok().and_then(|s|serde_json::from_slice(&s).ok()).unwrap_or(json!({}))}
pub fn latest_log(directory:&Path)->Option<PathBuf>{fs::read_dir(directory).ok()?.flatten().filter(|p|p.path().extension().is_some_and(|s|s=="log")).max_by_key(|p|p.metadata().and_then(|m|m.modified()).ok()).map(|p|p.path())}
