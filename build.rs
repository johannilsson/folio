use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=frontend/src");
    println!("cargo:rerun-if-changed=frontend/package.json");
    println!("cargo:rerun-if-changed=frontend/vite.config.ts");

    if std::env::var("FOLIO_SKIP_FRONTEND_BUILD").is_ok() {
        return;
    }

    let status = Command::new("pnpm")
        .arg("install")
        .current_dir("frontend")
        .status()
        .expect("pnpm not found — install it with: npm i -g pnpm");

    assert!(status.success(), "pnpm install failed");

    let status = Command::new("pnpm")
        .arg("build")
        .current_dir("frontend")
        .status()
        .expect("pnpm not found");

    assert!(status.success(), "pnpm build failed");
}
