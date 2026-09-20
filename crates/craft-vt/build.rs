use std::{env, fs, path::PathBuf, process::Command};

const REVISION: &str = "82938b633ba646db38591d969c3c526332bd7e65";

fn run(command: &mut Command) {
    assert!(
        command
            .status()
            .expect("could not start native compiler")
            .success(),
        "native compilation failed"
    );
}

fn main() {
    println!("cargo:rerun-if-env-changed=CRAFT_GHOSTTY_VT_DIR");
    println!("cargo:rerun-if-changed=native/terminal.c");
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let runtime = env::var_os("CRAFT_GHOSTTY_VT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("../../macos/.build/ghostty-vt/runtime"));
    let revision = runtime.join("taskhub-ghostty-revision");
    println!("cargo:rerun-if-changed={}", revision.display());
    assert_eq!(
        fs::read_to_string(revision)
            .expect("Run macos/scripts/build-ghostty-vt.py first")
            .trim(),
        REVISION,
        "The daemon and native renderer must use the same pinned Ghostty snapshot format"
    );
    let query_patch = root.join("../../macos/patches/ghostty/0003-terminal-query-validation.patch");
    let applied_patch = runtime.join("taskhub-ghostty-query-patch");
    println!("cargo:rerun-if-changed={}", query_patch.display());
    println!("cargo:rerun-if-changed={}", applied_patch.display());
    assert_eq!(
        fs::read(applied_patch).expect("Rebuild the headless runtime with build-ghostty-vt.py"),
        fs::read(query_patch).expect("missing shared terminal query patch"),
        "The headless runtime needs the same query validation patch as the native renderer"
    );
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let glyph_patch = root.join("../../macos/patches/ghostty/0007-glyph-snapshot.patch");
    let applied_glyph_patch = runtime.join("taskhub-ghostty-glyph-patch");
    println!("cargo:rerun-if-changed={}", glyph_patch.display());
    println!("cargo:rerun-if-changed={}", applied_glyph_patch.display());
    assert_eq!(
        fs::read(applied_glyph_patch).expect("Rebuild the headless runtime with build-ghostty-vt.py"),
        fs::read(glyph_patch).expect("missing shared glyph snapshot patch"),
        "The daemon and native renderer require the same glyph snapshot extension"
    );
    let graphics_patch = root.join("../../macos/patches/ghostty/0008-graphics-snapshot.patch");
    let applied_graphics_patch = runtime.join("taskhub-ghostty-graphics-patch");
    println!("cargo:rerun-if-changed={}", graphics_patch.display());
    println!("cargo:rerun-if-changed={}", applied_graphics_patch.display());
    assert_eq!(
        fs::read(applied_graphics_patch).expect("Rebuild the headless runtime with build-ghostty-vt.py"),
        fs::read(graphics_patch).expect("missing shared graphics snapshot patch"),
        "The daemon and native renderer require the same graphics snapshot extension"
    );
    let archive = runtime.join("lib/libghostty-vt.a");
    println!("cargo:rerun-if-changed={}", archive.display());
    // Apple ld can prefer a same-named dylib for -l arguments. Give the bundled
    // archive a unique name so the daemon never gains a development-only rpath.
    fs::copy(archive, out.join("libcraft-ghostty-core.a"))
        .expect("missing Ghostty static archive");
    let object = out.join("terminal.o");
    run(Command::new("cc")
        .args([
            "-std=c11",
            "-O2",
            "-DGHOSTTY_STATIC",
            "-c",
            "native/terminal.c",
            "-I",
        ])
        .arg(runtime.join("include"))
        .arg("-o")
        .arg(&object));
    run(Command::new("ar")
        .arg("crs")
        .arg(out.join("libcraft-vt-shim.a"))
        .arg(object));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=craft-vt-shim");
    println!("cargo:rustc-link-lib=static=craft-ghostty-core");
    println!("cargo:rustc-link-lib=c++");
}
