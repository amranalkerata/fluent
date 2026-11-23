# Vendor

## llama.xcframework

Prebuilt [llama.cpp](https://github.com/ggml-org/llama.cpp) (llama + ggml + the
multimodal `mtmd` library) for the offline Arabic ASR engine
(Audar-ASR-V1-Turbo / Qwen3-ASR, GGUF + mmproj). Swift imports it as `import llama`.

| | |
|---|---|
| Source | https://github.com/ggml-org/llama.cpp (official repo, no fork) |
| Tag | `v1.0.0` (2026-11-13) |
| Commit | `b1b770d90d94cad9e9ea5b993bdbc383a522fb28` |
| License | MIT, see [`LICENSE-llama.cpp`](LICENSE-llama.cpp) |
| Slice | `macos-arm64_x86_64` (universal), deployment target macOS 14.0 |
| Type | dynamic framework (embed and sign in the app) |
| Backends | Metal (kernels embedded in the binary), BLAS (Accelerate), CPU |
| Headers | `llama.h`, `ggml*.h`, `gguf.h`, `mtmd.h`, `mtmd-helper.h` |

Qwen3-ASR audio is supported at this tag: projector type `PROJECTOR_TYPE_QWEN3A`
(`"qwen3a"`) in `tools/mtmd/mtmd-impl.h`, graph in `tools/mtmd/models/qwen3a.cpp`,
audio preprocessor `mtmd_audio_preprocessor_qwen3a` in `tools/mtmd/mtmd-audio.cpp`.

### Rebuild

The upstream `build-xcframework.sh` builds every Apple platform, universal macOS
(arm64 + x86_64) and a 13.3 minimum. We build only the macOS slice, keep it
universal so the app can still be archived for "Any Mac", and raise the minimum
to the app's deployment target — one line changed:

```diff
-MACOS_MIN_OS_VERSION=13.3
+MACOS_MIN_OS_VERSION=14.0
```

```sh
git clone --depth 1 --branch v1.0.0 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
sed 's/^MACOS_MIN_OS_VERSION=13.3/MACOS_MIN_OS_VERSION=14.0/' build-xcframework.sh > build-xcframework-macos.sh
bash ./build-xcframework-macos.sh macos              # needs cmake on PATH
# output: build-apple/llama.xcframework  ->  copy with `ditto` to Vendor/llama.xcframework
```

The script's defaults stay as upstream has them: `BUILD_SHARED_LIBS=OFF` (static
libs combined into one dylib), `LLAMA_BUILD_MTMD=ON`, `GGML_METAL=ON`,
`GGML_METAL_EMBED_LIBRARY=ON`, `GGML_BLAS_DEFAULT=ON`, `GGML_NATIVE=OFF`,
`GGML_OPENMP=OFF`. Built with Xcode 27.2 and CMake 4.4.5.

### Notes

- `GGML_METAL_EMBED_LIBRARY=ON` embeds the Metal kernel *sources* in the binary.
  The first Metal init on a machine compiles them (about 6 s on an M3 Pro, on
  the thread that calls `llama_backend_init()` or first touches the GPU); later
  launches load them from macOS's shader cache in about 0.02 s. A precompiled
  `default.metallib` needs `GGML_METAL_EMBED_LIBRARY=OFF` and the Metal
  Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- The dSYM (`macos-arm64_x86_64/dSYMs/llama.dSYM`) is stored with Git LFS
  (see `.gitattributes`).
- `MTMD_VIDEO` is on for the macOS build upstream (video input via an `ffmpeg`
  subprocess). Fluent only uses audio, so this path is never hit.
- Third-party code compiled into the binary keeps its own notices in the
  llama.cpp source tree (`vendor/miniaudio`, `vendor/stb`, `vendor/hash`).
