
# text-observer

> A cross-platform (Mac/Windows) library for observing OS-level text selections, processing text, updating clipboard, and automatic pasting.

## 🚀 Features

- Real-time OS-level text selection observing.
- Automatic clipboard updating and pasting.
- Easy Node.js integration with Electron and standard Node apps.

## 📦 Installation

```bash
npm install text-observer
```

🛠 Usage
```js
const { startSelectionObserver } = require('text-observer');

startSelectionObserver((selection, paste) => {
  console.log('Text selected:', selection.text);

  const processedText = selection.text.toUpperCase();
  paste(processedText);
});
```

🖥 Supported Platforms
OS	Support
macOS ✅	Fully supported
Windows 🟡	Coming soon

🤝 Contributing
Open issues or pull requests are welcomed!

