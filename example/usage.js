const { startSelectionObserver } = require('..');

startSelectionObserver((selection, paste) => {
  console.log('Received selection:', selection);

  // Example: processing logic
  // const processedText = selection.text.toUpperCase();

  // // Return processed text to paste
  // paste(processedText);
});
