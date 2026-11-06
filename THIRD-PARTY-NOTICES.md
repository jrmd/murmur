# Third-party notices

Murmur itself is released under the [MIT License](LICENSE). It builds on the following software and models, each under its own terms. The same list is available in the app under Settings → About → Acknowledgements.

## Software

| Component | Used for | License |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Core ML speech recognition runtime for Apple silicon | Apache License 2.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | On-device inference for the clean-up model (linked as a prebuilt xcframework) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Software updates | MIT (see its [LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) for bundled components) |

Dependencies are fetched by Swift Package Manager at build time and are not stored in this repository.

## Models

Models are not part of this repository or of the app download. They are fetched from Hugging Face on first use, and you are bound by their licenses when you download them.

| Model | Used for | License |
| --- | --- | --- |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (NVIDIA) | Speech recognition (v2 also available) | CC BY 4.0 |
| [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) (moondream) | Speech recognition, post-trained from v3 | CC BY 4.0 |
| [Murmur Clean 350M](https://huggingface.co/bonusobjective/murmur-clean-350m) (Bonus Objective) | Clean-up, fine-tuned from Liquid AI LFM2.5-350M | LFM Open License v1.0 |
| [LFM3 1.7B](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF) (Liquid AI) | Optional larger clean-up model | LFM Open License v1.0 |

Any custom clean-up model you choose in Settings is governed by the license of its Hugging Face repository.

## Design assets

The app icon and menu bar icons in `murmur-icons` and `Sources/Murmur/Assets.xcassets` are part of this repository and covered by the MIT License. If you distribute a modified build, please use your own name and icon.
