use serde_json::{json, Value};
use std::{fs, io::Write, os::unix::fs::PermissionsExt, path::Path};

pub fn defaults() -> Value {
    json!({"renderer":"opengl","gpu":"auto","display_backend":"wayland","dns":"quad9","dns_custom":"",
        "mouse_sensitivity":1.0,"scroll_sensitivity":1.5,"dpi_scale":1.0,"framerate_cap":0,
        "raw_mouse":true,"auto_patch_throttle":true,"hide_menu_bar":true,"keep_logs":30,
        "show_launcher_after_exit":true,"hide_launcher_on_launch":false,"playtime_seconds":0,
        "enable_custom_mods":true,"enabled_mods":[],"trace_gl":false,"trace_udp":false,"diagnostic_signals":false})
}

pub fn load(path: &Path) -> Value {
    let mut settings = defaults();
    if let Ok(raw) = fs::read(path) {
        if let Ok(Value::Object(stored)) = serde_json::from_slice::<Value>(&raw) {
            settings.as_object_mut().unwrap().extend(stored);
        }
    }
    settings
}

pub fn validate_patch(patch: &Value) -> Result<(), String> {
    let fields = patch.as_object().ok_or("Settings must be an object")?;
    for (key, value) in fields {
        let valid = match key.as_str() {
            "renderer" => matches!(value.as_str(), Some("opengl" | "vulkan" | "metal")),
            "display_backend" => matches!(value.as_str(), Some("x11" | "wayland")),
            "dns" => matches!(value.as_str(), Some("quad9" | "cloudflare" | "google" | "custom" | "system")),
            "gpu" => value.as_str().is_some_and(|s| s == "auto" || (s.starts_with("pci:") && s.len() < 40 && s.chars().all(|c| c.is_ascii_hexdigit() || ":.pci".contains(c)))),
            "dns_custom" => value.as_str().is_some_and(|s| s.len() < 256 && !s.contains(char::is_whitespace)),
            "mouse_sensitivity" | "scroll_sensitivity" => value.as_f64().is_some_and(|n| (0.1..=10.0).contains(&n)),
            "dpi_scale" => value.as_f64().is_some_and(|n| (1.0..=4.0).contains(&n)),
            "framerate_cap" => value.as_u64().is_some_and(|n| n <= 1000),
            "keep_logs" => value.as_u64().is_some_and(|n| (1..=100).contains(&n)),
            "enabled_mods" => value.as_array().is_some_and(|items| items.len() <= 128 && items.iter().all(|v| v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 100 && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_ ".contains(c))))),
            "raw_mouse" | "auto_patch_throttle" | "hide_menu_bar" | "show_launcher_after_exit" | "hide_launcher_on_launch" | "enable_custom_mods" | "trace_gl" | "trace_udp" | "diagnostic_signals" => value.is_boolean(),
            _ => return Err(format!("Unknown setting: {key}")),
        };
        if !valid { return Err(format!("Invalid value for {key}")); }
    }
    Ok(())
}

pub fn write_atomic(path: &Path, value: &Value) -> Result<(), String> {
    let parent = path.parent().ok_or("Settings path has no parent")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    temporary.as_file().set_permissions(fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    temporary.write_all(&serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    temporary.as_file().sync_all().map_err(|e| e.to_string())?;
    temporary.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn rejects_invalid_values_before_writing() {
        for patch in [json!({"renderer":"../../anything"}), json!({"dpi_scale":0.0}), json!({"framerate_cap":-1}), json!({"raw_mouse":"yes"}), json!({"enabled_mods":["../outside"]})] { assert!(validate_patch(&patch).is_err()); }
        assert!(validate_patch(&json!({"renderer":"vulkan","dpi_scale":1.5,"framerate_cap":144})).is_ok());
    }
    #[test] fn saves_privately_without_losing_legacy_preferences() {
        let dir = tempfile::tempdir().unwrap(); let path = dir.path().join("settings.json");
        write_atomic(&path, &json!({"renderer":"vulkan","old_preference":"preserve"})).unwrap();
        let value=load(&path); assert_eq!(value["renderer"],"vulkan"); assert_eq!(value["old_preference"],"preserve");
        assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777,0o600);
    }
}
