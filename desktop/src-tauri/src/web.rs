//! Endpoint for the shim's embedded-web bridge (native/web_bridge.m).
//!
//! Roblox's macOS client attaches to its web view host at startup; without
//! QUINTA_WEB_SOCKET the shim leaves Darling's stub WebKit in place and the
//! client never reaches its home screen (a black window). This side speaks the
//! same JSON-lines protocol as launcher/quinta/web.py: requests ({"op": ...})
//! in, events ({"event": ...}) out. Pages are not shown yet: requests that
//! need a browser get an error reply so the game never waits on them.
use serde_json::{json, Value};
use std::{fs, io::{BufRead, BufReader, Write}, os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}}, path::{Path,PathBuf},process::{Child,Command,Stdio}, sync::{Arc, atomic::{AtomicBool, Ordering}}, thread, time::Duration};

const MAX_LINE: usize = 1024 * 1024;

pub struct WebBridge { pub guest_path: String, pub user_agent: Option<String>, path: PathBuf, stop: Arc<AtomicBool>, host:Option<Child> }

impl Drop for WebBridge {
    fn drop(&mut self) { if let Some(host)=&mut self.host{let _=host.kill();let _=host.wait();} self.stop.store(true, Ordering::Relaxed); let _ = fs::remove_file(&self.path); }
}

impl WebBridge {
    /// The full WebKitGTK host (launcher/quinta/web.py) for the client's
    /// sign-in, profile and purchase pages. `embed`: the client runs on X11
    /// and the host draws pages inside the client's own windows (Studio);
    /// otherwise pages open in the host's browser window.
    pub fn start_host(root:&Path,embed:bool)->Result<Self,String>{
        let mut command=Command::new("python3");
        command.args(["-m","quinta.studio_web_host"])
            .env("PYTHONPATH",root.join("launcher"))
            .env("WEBKIT_DISABLE_DMABUF_RENDERER","1");
        if embed{command.env("GDK_BACKEND","x11").env("QUINTA_WEB_EMBED","1");}
        let mut child=command
            .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::inherit())
            .spawn().map_err(|e|format!("Could not start the WebKit host: {e}"))?;
        let output=child.stdout.take().unwrap();
        let (sender,receiver)=std::sync::mpsc::channel();
        thread::spawn(move ||{let mut line=String::new();let result=BufReader::new(output).read_line(&mut line).map(|_|line);let _=sender.send(result);});
        let line=receiver.recv_timeout(Duration::from_secs(15)).ok().and_then(Result::ok);
        let line=line.unwrap_or_default();
        let (guest_path,user_agent)=line.trim_end().split_once('\t').unwrap_or((line.trim_end(),""));
        let user_agent=Some(user_agent.to_string()).filter(|a|!a.is_empty()&&a.bytes().all(|b|(32..127).contains(&b)));
        let Some(guest_path)=Some(guest_path.to_string()).filter(|s|s.starts_with("/Volumes/SystemRoot/")) else{
            let _=child.kill();let _=child.wait();return Err("The WebKit host did not start. Install Python GObject, GTK4, libadwaita and WebKitGTK 6.".into());
        };
        let path=PathBuf::from(guest_path.strip_prefix("/Volumes/SystemRoot").unwrap());
        Ok(Self{guest_path,user_agent,path,stop:Arc::new(AtomicBool::new(false)),host:Some(child)})
    }
    pub fn start() -> Result<Self, String> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
        let path = runtime.join(format!("quinta-web-{}.sock", std::process::id()));
        let guest_path = format!("/Volumes/SystemRoot{}", path.display());
        // Unix socket paths are limited to 104 bytes as the guest sees them.
        if guest_path.len() >= 104 { return Err("Web bridge socket path is too long".into()); }
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).map_err(|e| format!("Could not start the web bridge: {e}"))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        thread::spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => { let flag = flag.clone(); thread::spawn(move || serve(stream, flag)); }
                    Err(_) => thread::sleep(Duration::from_millis(100)),
                }
            }
        });
        Ok(Self { guest_path, user_agent:None, path, stop, host:None })
    }
}

fn serve(stream: UnixStream, stop: Arc<AtomicBool>) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let Ok(mut writer) = stream.try_clone() else { return };
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    while !stop.load(Ordering::Relaxed) {
        match reader.read_until(b'\n', &mut line) {
            Ok(0) => return,
            Ok(_) if line.ends_with(b"\n") => {
                if let Ok(message) = serde_json::from_slice::<Value>(&line) {
                    if let Some(reply) = reply_for(&message) {
                        let mut bytes = serde_json::to_vec(&reply).unwrap_or_default();
                        bytes.push(b'\n');
                        if writer.write_all(&bytes).is_err() { return; }
                    }
                }
                line.clear();
            }
            Ok(_) => {}
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
            Err(_) => return,
        }
        if line.len() > MAX_LINE { return; }
    }
}

/// Only requests carry a "request" number and expect a reply.
fn reply_for(message: &Value) -> Option<Value> {
    let number = message.get("request").filter(|n| n.is_u64())?;
    let view = message.get("view").cloned().unwrap_or(json!(0));
    Some(match message.get("op").and_then(Value::as_str) {
        Some("cookies-get") => json!({"view": view, "event": "reply", "request": number, "value": []}),
        _ => json!({"view": view, "event": "reply", "request": number, "error": "Embedded pages are not available in this Quinta build"}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn notifications_get_no_reply() { assert!(reply_for(&json!({"op":"attach","window":5})).is_none()); }
    #[test] fn requests_never_wait() {
        assert_eq!(reply_for(&json!({"op":"cookies-get","request":3})).unwrap()["value"], json!([]));
        assert!(reply_for(&json!({"op":"eval","view":1,"request":4})).unwrap()["error"].is_string());
    }
}
