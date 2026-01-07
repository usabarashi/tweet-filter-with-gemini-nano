# Tweet Filter with Gemini Nano

A Chrome Extension that filters tweets on Twitter/X using on-device AI with Gemini Nano.

## Features

- **Complete privacy protection**: All processing happens locally on your device using Gemini Nano in real-time as you scroll - no data is sent to external servers, ensuring your browsing activity remains private
- **Customizable prompts**: Define your own filtering criteria in the Options page
- **Multimodal analysis**: Evaluates both text and images separately, shows tweets if either content matches your criteria

## Requirements

- Chrome 131 or later
- Gemini Nano with required Chrome flags enabled
- See [Get started with built-in AI](https://developer.chrome.com/docs/ai/get-started) for setup instructions and system requirements

**Note**: The extension works in text-only mode, but enabling the multimodal flag (`chrome://flags/#prompt-api-for-gemini-nano-multimodal-input`) is required for image analysis.

## Installation

1. Clone this repository
2. Install dependencies and build:
   ```bash
   npm install
   npm run build
   ```
3. Load the extension in Chrome:
   - Open Chrome and navigate to `chrome://extensions/`
   - Enable "Developer mode" (toggle in top right)
   - Click "Load unpacked"
   - Select the `dist` folder from the project directory

## Usage

1. Open the extension Options page (right-click extension icon → Options)
2. Follow the on-screen instructions to:
   - Enable required Chrome flags
   - Download Gemini Nano model (first time only)
   - Configure your filtering criteria
3. Visit Twitter/X and tweets will be automatically filtered based on your criteria

## References

- [Built-in AI](https://developer.chrome.com/docs/ai/built-in)
- [The Prompt API](https://developer.chrome.com/docs/ai/prompt-api)
