use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{fs, path::{Path,PathBuf}, process::Command};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Runtime {
    #[serde(default="default_variant")] pub runtime: String,
    pub executable: PathBuf, pub sysroot: PathBuf, pub prefix: PathBuf,
}
fn default_variant() -> String { "ciderdarling".into() }
impl Runtime {
    pub fn validate(&self) -> Result<(),String> {
        if !matches!(self.runtime.as_str(),"ciderdarling"|"regular") { return Err("Unknown runtime type".into()); }
        for p in [&self.executable,&self.sysroot,&self.prefix] {
            if !p.is_absolute() || p.as_os_str().to_string_lossy().contains(['\n','\r','\0']) { return Err("Runtime locations must be absolute paths".into()); }
        }
        if !self.executable.is_file() { return Err(format!("Runtime executable is missing: {}",self.executable.display())); }
        if !self.sysroot.is_dir() { return Err("The selected runtime's system root is missing".into()); }
        Ok(())
    }
}
pub fn read(path:&Path)->Result<Runtime,String> {
    let data=fs::read(path).map_err(|_|"Choose your CiderDarling runtime in Settings".to_string())?;
    if data.len()>16_384{return Err("Runtime selection is too large".into());}
    let runtime:Runtime=serde_json::from_slice(&data).map_err(|e|format!("Invalid runtime selection: {e}"))?;
    runtime.validate()?; Ok(runtime)
}

#[derive(Clone,Debug,Serialize)]
pub struct Gpu { pub id:String,pub name:String,pub memory_mib:u64 }
pub fn gpus()->Vec<Gpu> {
    let mut found=Vec::new();
    if let Ok(out)=Command::new("nvidia-smi").args(["--query-gpu=pci.bus_id,name,memory.total","--format=csv,noheader,nounits"]).output(){
        if out.status.success(){for row in String::from_utf8_lossy(&out.stdout).lines(){let parts:Vec<_>=row.split(',').map(str::trim).collect();if parts.len()==3{
            let address=normalize_pci(parts[0]);
            found.push(Gpu{id:format!("pci:{address}"),name:parts[1].into(),memory_mib:parts[2].parse().unwrap_or(0)});
        }}}
    }
    if let Ok(entries)=fs::read_dir("/sys/class/drm") {for entry in entries.flatten(){
        let name=entry.file_name().to_string_lossy().into_owned();if !name.starts_with("renderD"){continue;}
        let device=entry.path().join("device");let Ok(uevent)=fs::read_to_string(device.join("uevent"))else{continue;};
        let Some(address)=uevent.lines().find_map(|l|l.strip_prefix("PCI_SLOT_NAME="))else{continue;};
        let id=format!("pci:{address}");if found.iter().any(|g|g.id==id){continue;}
        let vendor=fs::read_to_string(device.join("vendor")).unwrap_or_default();
        let label=match vendor.trim(){"0x1002"=>"AMD graphics","0x8086"=>"Intel graphics",_=>"Graphics adapter"};
        let bytes=fs::read_to_string(device.join("mem_info_vram_total")).ok().and_then(|s|s.trim().parse::<u64>().ok()).unwrap_or(0);
        found.push(Gpu{id,name:format!("{label} ({address})"),memory_mib:bytes/1_048_576});
    }}
    found
}
fn normalize_pci(address:&str)->String {let parts:Vec<_>=address.split(':').collect();if parts.len()==3{format!("{:0>4}:{}:{}",parts[0].trim_start_matches('0'),parts[1],parts[2])}else{address.into()}}

pub fn graphics(settings:&Value, inventory:&[Gpu], root:&Path)->Result<Vec<(String,String)>,String>{
    let mut env=Vec::new();let renderer=settings["renderer"].as_str().unwrap_or("opengl");
    let selected=settings["gpu"].as_str().unwrap_or("auto");
    let gpu=if selected=="auto"{inventory.iter().find(|g|g.name.contains("NVIDIA")).or(inventory.first())}else{inventory.iter().find(|g|g.id==selected)};
    if selected!="auto" && gpu.is_none(){return Err("The selected GPU is unavailable. Choose Automatic in Settings.".into());}
    if let Some(gpu)=gpu{
        let address=gpu.id.trim_start_matches("pci:");
        // "!" restricts Vulkan's physical-device list to this card, which
        // Zink (Vulkan) and Metal need; OpenGL only uses the PRIME selector.
        let vulkan_device=matches!(renderer,"vulkan"|"metal");
        env.push(("DRI_PRIME".into(),format!("pci-{}{}",address.replace([':', '.'],"_"),if vulkan_device{"!"}else{""})));
        let nvidia=gpu.name.contains("NVIDIA");
        env.extend([
            ("__NV_PRIME_RENDER_OFFLOAD".into(),if nvidia{"1"}else{"0"}.into()),
            ("__GLX_VENDOR_LIBRARY_NAME".into(),if nvidia{"nvidia"}else{"mesa"}.into()),
            ("__VK_LAYER_NV_optimus".into(),if nvidia{"NVIDIA_only"}else{"non_NVIDIA_only"}.into()),
            ("MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE".into(),"1".into()),
        ]);
        if nvidia && renderer=="opengl"{env.push(("__EGL_VENDOR_LIBRARY_FILENAMES".into(),"/usr/share/glvnd/egl_vendor.d/10_nvidia.json".into()));}
        let budget=if gpu.memory_mib>0{gpu.memory_mib*1_048_576*3/4}else{512*1_048_576};
        env.push(("QUINTA_VRAM_BYTES".into(),budget.to_string()));
    }
    match renderer{
        "opengl"=>{},
        "vulkan"=>{
            let mesa=["/usr/share/glvnd/egl_vendor.d/50_mesa.json","/usr/local/share/glvnd/egl_vendor.d/50_mesa.json"].into_iter().find(|p|Path::new(p).is_file()).ok_or("Vulkan requires Mesa EGL and Zink. Select OpenGL or install Mesa.")?;
            env.extend([("MACOBLOX_METAL".into(),"0".into()),("MESA_LOADER_DRIVER_OVERRIDE".into(),"zink".into()),("GALLIUM_DRIVER".into(),"zink".into()),("__EGL_VENDOR_LIBRARY_FILENAMES".into(),mesa.into())]);
        },
        "metal"=>{
            let metal=root.join("build/metal");if !metal.join("libquinta_metal_host.so").is_file(){return Err("The experimental Metal bridge has not been built. Choose OpenGL or Vulkan.".into());}
            env.extend([("MACOBLOX_METAL".into(),"1".into()),("MACOBLOX_METAL_FRAMEWORKS".into(),format!("/Volumes/SystemRoot{}",metal.display())),("MACOBLOX_METAL_HOST_LIBRARY".into(),metal.join("libquinta_metal_host.so").display().to_string())]);
        },_=>return Err("Unknown renderer".into())
    }
    let backend=settings["display_backend"].as_str().unwrap_or("wayland");
    if backend=="wayland"{
        if std::env::var_os("WAYLAND_DISPLAY").is_none(){return Err("This desktop session has no Wayland display. Choose X11 in Settings.".into());}
        let helper=root.join("build/libquinta-wayland.so");if !helper.is_file(){return Err("The Wayland helper is missing. Rebuild the native shims or select X11.".into());}
        env.extend([("QUINTA_WAYLAND".into(),"1".into()),("EGL_PLATFORM".into(),"wayland".into()),("QUINTA_WAYLAND_HELPER".into(),helper.display().to_string())]);
        if matches!(renderer,"vulkan"|"metal"){env.extend(wayland_vulkan_driver());}
    }else{env.extend([("QUINTA_WAYLAND".into(),"0".into()),("EGL_PLATFORM".into(),"x11".into())]);}
    // Linux layers see host paths even though Darling rewrites HOME to /Users.
    let config=std::env::var_os("XDG_CONFIG_HOME").map(std::path::PathBuf::from).unwrap_or_else(||home().join(".config"));
    env.push(("XDG_CONFIG_HOME".into(),config.display().to_string()));
    Ok(env)
}

/// The primary monitor's refresh rate (KDE's kscreen-doctor), so Roblox offers
/// and keeps frame-rate caps above 60.
pub fn display_hz()->Option<u32>{
    let out=Command::new("kscreen-doctor").arg("-j").output().ok()?;
    let data:Value=serde_json::from_slice(&out.stdout).ok()?;
    let outputs=data["outputs"].as_array()?;
    let enabled:Vec<&Value>=outputs.iter().filter(|o|o["enabled"].as_bool()==Some(true)).collect();
    let primary=enabled.iter().find(|o|o["priority"].as_u64()==Some(1)).or(enabled.first())?;
    let current=primary["currentModeId"].as_str()?;
    let mode=primary["modes"].as_array()?.iter().find(|m|m["id"].as_str()==Some(current))?;
    mode["refreshRate"].as_f64().map(|hz|hz.round() as u32).filter(|hz|(30..=1000).contains(hz))
}

fn home()->std::path::PathBuf{std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_else(||"/".into())}

/// NVIDIA's default Vulkan ICD goes through libGLX, which fails without an X11
/// DISPLAY. Its EGL library exposes the same driver, so add a manifest pointing
/// there; the loader keeps its normal search for any other GPUs.
fn wayland_vulkan_driver()->Vec<(String,String)>{
    let mut env:Vec<(String,String)>=["VK_LOADER_DRIVERS_SELECT","VK_LOADER_DRIVERS_DISABLE"].iter().filter_map(|k|std::env::var(k).ok().map(|v|(k.to_string(),v))).collect();
    let overrides:Vec<(String,String)>=["VK_DRIVER_FILES","VK_ICD_FILENAMES","VK_ADD_DRIVER_FILES"].iter().filter_map(|k|std::env::var(k).ok().map(|v|(k.to_string(),v))).collect();
    if !overrides.is_empty(){env.extend(overrides);return env;}
    let roots=[std::env::var_os("XDG_CONFIG_HOME").map(std::path::PathBuf::from).unwrap_or_else(||home().join(".config")),"/etc/xdg".into(),"/usr/local/etc".into(),"/etc".into(),home().join(".local/share"),"/usr/local/share".into(),"/usr/share".into()];
    let libraries=["/usr/lib","/usr/lib64","/usr/lib/x86_64-linux-gnu","/usr/lib/x86_64-linux-gnu/nvidia/current","/usr/lib/nvidia/current","/usr/local/lib"];
    for root in roots{
        let Ok(entries)=fs::read_dir(root.join("vulkan/icd.d"))else{continue};
        let mut paths:Vec<_>=entries.flatten().map(|e|e.path()).filter(|p|p.extension().is_some_and(|x|x=="json")).collect();paths.sort();
        for path in paths{
            let Ok(mut manifest)=fs::read_to_string(&path).map_err(|_|()).and_then(|t|serde_json::from_str::<Value>(&t).map_err(|_|()))else{continue};
            let Some(library)=manifest["ICD"]["library_path"].as_str().map(str::to_string)else{continue};
            if Path::new(&library).file_name().is_none_or(|n|n!="libGLX_nvidia.so.0")||manifest["ICD"]["library_arch"]=="32"{continue;}
            let replacement=library.replace("libGLX_nvidia.so.0","libEGL_nvidia.so.0");
            let egl=if replacement.contains('/'){Some(std::path::PathBuf::from(&replacement))}else{libraries.iter().map(|d|Path::new(d).join(&replacement)).find(|p|p.is_file())};
            let Some(egl)=egl.filter(|p|p.is_file()).and_then(|p|p.canonicalize().ok())else{continue};
            manifest["ICD"]["library_path"]=Value::String(egl.display().to_string());
            let payload=serde_json::to_string_pretty(&manifest).unwrap_or_default();
            let digest=payload.bytes().fold(0xcbf29ce484222325u64,|h,b|(h^b as u64).wrapping_mul(0x100000001b3));
            let cache=std::env::var_os("XDG_CACHE_HOME").map(std::path::PathBuf::from).unwrap_or_else(||home().join(".cache")).join("quinta/vulkan");
            // Keep the source basename: loader select/disable filters match it.
            let target=cache.join(format!("nvidia-egl-{digest:016x}")).join(path.file_name().unwrap());
            if fs::read_to_string(&target).ok().as_deref()!=Some(payload.as_str()){
                if crate::settings::write_atomic(&target,&manifest).is_err(){return env;}
            }
            env.push(("VK_ADD_DRIVER_FILES".into(),target.display().to_string()));
            return env;
        }
    }
    env
}

#[cfg(test)]mod tests{use super::*;
    #[test]fn gpu_identity_is_stable(){assert_eq!(normalize_pci("00000000:01:00.0"),"0000:01:00.0");assert_eq!(normalize_pci("0000:0d:00.0"),"0000:0d:00.0");}
    #[test]fn missing_selected_gpu_does_not_silently_use_another(){let s=serde_json::json!({"gpu":"pci:0000:01:00.0"});assert!(graphics(&s,&[],Path::new("/tmp")).is_err());}
}
#[cfg(test)]mod live{use super::*;
    // Prints this machine's launch graphics: cargo test -- --ignored --nocapture
    #[test]#[ignore]fn print_vulkan_environment(){let s=serde_json::json!({"renderer":"vulkan","gpu":"auto","display_backend":"wayland"});for (k,v) in graphics(&s,&gpus(),Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").as_path()).unwrap(){eprintln!("{k}={v}");}}
}
