use std::{ffi::CString,fs::{self,File,OpenOptions},os::unix::fs::OpenOptionsExt,path::{Path,PathBuf},process::{Child,Command,Stdio}};

pub struct Audio {pub fifo:PathBuf,child:Child,_guard:File}
impl Drop for Audio {fn drop(&mut self){let _=self.child.kill();let _=self.child.wait();let _=fs::remove_file(&self.fifo);}}
pub fn program_exists(name:&str)->bool{std::env::var_os("PATH").map(|p|std::env::split_paths(&p).any(|d|d.join(name).is_file())).unwrap_or(false)}
impl Audio{
 pub fn start(cache:&Path)->Result<Option<Self>,String>{
    if std::env::var("QUINTA_AUDIO").as_deref()==Ok("0"){return Ok(None);}
    let pipewire=program_exists("pw-cat") && Command::new("pw-cat").arg("--help").output().ok().is_some_and(|o|String::from_utf8_lossy(&o.stdout).contains("--raw"));
    if !pipewire && !program_exists("pacat"){return Ok(None);}
    fs::create_dir_all(cache).map_err(|e|e.to_string())?;
    let fifo=cache.join(format!("audio-{}.fifo",std::process::id()));let _=fs::remove_file(&fifo);
    let name=CString::new(fifo.as_os_str().as_encoded_bytes()).map_err(|e|e.to_string())?;
    if unsafe{libc::mkfifo(name.as_ptr(),0o600)}!=0{return Err(std::io::Error::last_os_error().to_string());}
    let guard=OpenOptions::new().read(true).write(true).custom_flags(libc::O_NONBLOCK).open(&fifo).map_err(|e|e.to_string())?;
    let mut command=if pipewire{let mut c=Command::new("pw-cat");c.args(["--playback","--raw","--format","f32","--rate","44100","--channels","2","--latency","40ms","--media-role","Game"]);c}else{let mut c=Command::new("pacat");c.args(["--playback","--raw","--format=float32le","--rate=44100","--channels=2","--latency-msec=40","--client-name=Roblox","--property=media.role=game"]);c};
    let child=command.arg(&fifo).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|e|e.to_string())?;
    Ok(Some(Self{fifo,child,_guard:guard}))
 }
}
