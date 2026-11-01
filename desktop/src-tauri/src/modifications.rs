use serde_json::{json,Value};
use std::{fs,path::{Path,PathBuf}};

pub fn list(root:&Path,settings:&Value)->Vec<Value>{
 let enabled=settings["enabled_mods"].as_array().cloned().unwrap_or_default();let mut found=Vec::new();
 if let Ok(entries)=fs::read_dir(root.join("modifications")){for e in entries.flatten(){if e.file_type().is_ok_and(|t|t.is_dir()&&!t.is_symlink()){
   let name=e.file_name().to_string_lossy().into_owned();found.push(json!({"name":name,"enabled":enabled.iter().any(|v|v.as_str()==Some(&name)),"path":e.path()}));
 }}}
 found.sort_by(|a,b|a["name"].as_str().cmp(&b["name"].as_str()));found
}
fn files(root:&Path,relative:&Path,result:&mut Vec<PathBuf>)->Result<(),String>{for entry in fs::read_dir(root.join(relative)).map_err(|e|e.to_string())?{let entry=entry.map_err(|e|e.to_string())?;let kind=entry.file_type().map_err(|e|e.to_string())?;if kind.is_symlink(){return Err("Custom mods cannot contain symbolic links".into());}let name=relative.join(entry.file_name());if kind.is_dir(){files(root,&name,result)?;}else if kind.is_file(){result.push(name);}}Ok(())}
pub fn apply(root:&Path,bundle:&Path,settings:&Value)->Result<(),String>{
 let manifest_path=root.join("mods_backup/applied.json");let previous=crate::state::read_json(&manifest_path);
 if let Some(entries)=previous.as_array(){for entry in entries{if let Some(relative)=entry.as_str(){let p=Path::new(relative);if !safe_relative(p){return Err("Invalid modification backup manifest".into());}let original=root.join("mods_backup/original").join(p);let target=bundle.join("Contents/Resources").join(p);if original.is_file(){if let Some(parent)=target.parent(){fs::create_dir_all(parent).map_err(|e|e.to_string())?;}fs::copy(original,target).map_err(|e|e.to_string())?;}}}}
 let mut applied=Vec::new();
 if settings["enable_custom_mods"].as_bool().unwrap_or(true){for item in settings["enabled_mods"].as_array().into_iter().flatten(){let name=item.as_str().ok_or("Invalid mod name")?;if name.contains(['/', '\\'])||name==".."{return Err("Invalid mod name".into());}let source=root.join("modifications").join(name);let mut entries=Vec::new();files(&source,Path::new(""),&mut entries)?;for relative in entries{
   if !safe_relative(&relative){return Err("Invalid mod path".into());}let target=bundle.join("Contents/Resources").join(&relative);let backup=root.join("mods_backup/original").join(&relative);
   if target.exists()&&!backup.exists(){fs::create_dir_all(backup.parent().unwrap()).map_err(|e|e.to_string())?;fs::copy(&target,&backup).map_err(|e|e.to_string())?;}
   if let Some(parent)=target.parent(){fs::create_dir_all(parent).map_err(|e|e.to_string())?;}fs::copy(source.join(&relative),target).map_err(|e|e.to_string())?;applied.push(relative.to_string_lossy().to_string());
 }}}
 crate::settings::write_atomic(&manifest_path,&json!(applied))
}
fn safe_relative(path:&Path)->bool{!path.is_absolute()&&path.components().all(|c|matches!(c,std::path::Component::Normal(_)))}
#[cfg(test)]mod tests{use super::*;#[test]fn paths_cannot_escape_resources(){for path in ["../outside","/etc/passwd","x/../../outside"]{assert!(!safe_relative(Path::new(path)));}assert!(safe_relative(Path::new("textures/cursor.png")));}}
