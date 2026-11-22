# RayPrompt — Local Gemma: status and how to enable it

**Status: not included in this build.** The app's `Gemma On-Device` provider only reports this state. It never generates text and never substitutes a cloud API.

## Chosen runtime (researched 2026-11-20)
- **LiteRT-LM** (Apache-2.0, `github.com/google-ai-edge/LiteRT-LM`) is Google's maintained on-device LLM runtime. It has a Swift API (SwiftPM product `LiteRTLM`, version ≥ 0.12.0) and Metal GPU acceleration.
- The MediaPipe LLM Inference API for iOS is deprecated in favour of LiteRT-LM.
- **Model format:** `.litertlm`. Candidates from the LiteRT Hugging Face community:
  - Gemma 4 E2B instruction-tuned (`litert-community/gemma-4-E2B-it-litert-lm`), referenced in Google's Swift guide;
  - Gemma 3n E2B (~2.9 GB) / E4B (~4.2 GB).

  Sizes and gating terms must be checked on the model page. Gemma weights are released under the Gemma terms, which may require accepting a licence before download.
- **Not the hosted Gemini API:** that is a different, cloud product.

## Exact blocker
`swift package resolve` with `.package(url: "https://github.com/google-ai-edge/LiteRT-LM", from: "0.12.0")` downloaded **2.7 GB** and then failed. The package's prebuilt runtime is stored in **Git LFS**, and `git-lfs` is not installed on the build Mac. I did not install system tools without permission.

## To enable it (needs your go-ahead)
1. On the Mac, run `brew install git-lfs && git lfs install`. If Xcode can't find it, link it into Xcode's toolchain as the package error explains.
2. Add the package in Xcode (File › Add Package Dependencies…) and link `LiteRTLM` to the app target.
3. Download a `.litertlm` Gemma model on the Mac. Accept the licence if the model is gated, and record its SHA-256 from the model page.
4. Copy the model into the app's Documents folder (Finder › iPhone › Files). Do not commit weights to Git.
5. Implement `GemmaProvider` against the installed package's actual Swift interface: `EngineConfig(modelPath:backend:cacheDir:)` → `Engine` → `initialize()` → `createConversation` → `sendMessageStream`. Use `.gpu`, lazy load, cancellation, and run off the main actor. Then verify the SHA-256 on load.
6. Run Settings › AI › **Answer evaluation** with Apple and with Gemma, and compare the exported reports.

**Unmeasured:** iOS latency, memory, battery, and thermal behaviour for any Gemma model on an iPhone 15 Pro Max. Choose the default from the on-device evaluation, not from published numbers.
