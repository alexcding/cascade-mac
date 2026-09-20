#!/usr/bin/env bash
# Shared by every script here that shells out to cargo. Source it, then call
# cargo_build in place of cargo.
#
# Cargo's fingerprints include the compiler environment, so a caller running
# under Xcode's environment (SDKROOT, MACOSX_DEPLOYMENT_TARGET, DEVELOPER_DIR,
# CC, …) and one running from a login shell invalidate each other's cache on a
# shared target directory. bootstrap.sh runs twice per Xcode build — once as the
# scheme's bare-environment pre-action, once as the build phase — which had
# libsqlite3-sys → rusqlite → craft-backend recompiling on nearly every run
# (~15 s a run, 287 of 300 runs in macos/.build/bootstrap.log). Routing cargo
# through one fixed environment puts every caller on the same fingerprint.
#
# PATH is a literal, not the caller's: Xcode's build phase puts its own toolchain
# dirs ahead of the login PATH, and craft-vt/build.rs compiles its shim with a
# bare `cc`/`ar`, so system /usr/bin wins for everyone. RUSTUP_TOOLCHAIN is
# deliberately NOT forwarded — the artifacts the app links should not change
# because a shell exported a nightly override. RUSTC_WRAPPER (sccache) is
# forwarded: it changes cache hits, never output.
# shellcheck shell=bash

CRAFT_CARGO_PATH="$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

cargo_build() {
  env -i \
    PATH="$CRAFT_CARGO_PATH" HOME="$HOME" \
    ${USER:+USER="$USER"} ${LOGNAME:+LOGNAME="$LOGNAME"} ${TMPDIR:+TMPDIR="$TMPDIR"} \
    ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} \
    ${RUSTC_WRAPPER:+RUSTC_WRAPPER="$RUSTC_WRAPPER"} \
    ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${HTTP_PROXY:+HTTP_PROXY="$HTTP_PROXY"} \
    ${ALL_PROXY:+ALL_PROXY="$ALL_PROXY"} ${NO_PROXY:+NO_PROXY="$NO_PROXY"} \
    cargo "$@"
}
