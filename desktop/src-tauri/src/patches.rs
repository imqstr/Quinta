//! Narrow compatibility repairs; unrecognized client data is left untouched.
use sha2::{Digest,Sha256};
use std::{fs,io::Write,path::Path};
fn positions(data:&[u8],needle:&[u8])->Vec<usize>{data.windows(needle.len()).enumerate().filter_map(|(i,s)|(s==needle).then_some(i)).collect()}
fn replace_atomic(path:&Path,data:&[u8])->Result<(),String>{let mode=fs::metadata(path).map_err(|e|e.to_string())?.permissions();let mut f=tempfile::NamedTempFile::new_in(path.parent().ok_or("No parent")?).map_err(|e|e.to_string())?;f.write_all(data).map_err(|e|e.to_string())?;f.as_file().set_permissions(mode).map_err(|e|e.to_string())?;f.persist(path).map_err(|e|e.to_string())?;Ok(())}
pub fn shaders(path:&Path)->Result<&'static str,String>{
 let mut data=fs::read(path).map_err(|e|e.to_string())?;
 if data.len()!=4_569_049 || format!("{:x}",Sha256::digest(&data))!="ead6fceac21e494cb3925ec4cc697ef7ea8773bff4617dffd4f9812cebcfa777"{return Ok("existing or unsupported shader pack left unchanged");}
 for offset in [0x39ffe1+0x52c,0x39ffe1+0x54b,0x3a537b+0x52c,0x3a537b+0x54b]{if data[offset]!=b' '{return Err("Shader repair precondition failed".into());}data[offset]=b'\t';}
 replace_atomic(path,&data)?;Ok("verified 745 shader repair applied")
}
fn throttle_site(data:&[u8],patched:bool)->Option<usize>{
 let null=b"\x41\xb8\x55\x00\x00\x00\xba\x02\x00\x00\x00\x41\xb9\x01\x00\x00\x00";
 let value=b"\x41\xb8\x4e\x00\x00\x00\xba\x03\x00\x00\x00\x41\xb9\x01\x00\x00\x00";
 let moves=if patched{b"\x31\xdb\x49\x89\xfe"}else{b"\x89\xf3\x49\x89\xfe"};
 for end in positions(data,null){let start=end.saturating_sub(0x600);for rel in positions(&data[start..end],moves).into_iter().rev(){let site=start+rel;let prologue=&data[site.saturating_sub(0x20)..site];if prologue.windows(4).any(|s|s==b"\x55\x48\x89\xe5") && data[site..(end+64).min(data.len())].windows(value.len()).any(|s|s==value){return Some(site);}}}None
}
pub fn throttle(path:&Path)->Result<&'static str,String>{let mut data=fs::read(path).map_err(|e|e.to_string())?;if let Some(site)=throttle_site(&data,false){data[site..site+2].copy_from_slice(b"\x31\xdb");replace_atomic(path,&data)?;Ok("startup throttle repaired")}else if throttle_site(&data,true).is_some(){Ok("startup throttle already repaired")}else{Ok("unrecognized throttle pattern left unchanged")}}
#[cfg(test)]mod tests{use super::*;
 #[test]fn lookalike_instructions_are_not_patched(){assert_eq!(throttle_site(b"\x55\x48\x89\xe5\x89\xf3\x49\x89\xfe",false),None);}
 #[test]fn unknown_shader_pack_is_not_modified(){let dir=tempfile::tempdir().unwrap();let p=dir.path().join("test.pack");fs::write(&p,b"unrecognized").unwrap();shaders(&p).unwrap();assert_eq!(fs::read(p).unwrap(),b"unrecognized");}
}
