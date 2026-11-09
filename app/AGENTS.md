# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- C API: `include/ghostty.h`
- macOS app: `macos/`
- Govi UI and build helpers: `govi/`
- This fork targets macOS only; unused platform app shells have been removed.

Use `./govi/build.sh` for a local Govi bundle. It bootstraps the pinned Zig compiler and runs `zig build`.

## macOS App

- Do not use `xcodebuild`
- Use `zig build` to build the macOS app and any shared Zig code
