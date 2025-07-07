const { onSelection, paste  } = require('..');

// Listen for new selections
onSelection(selection => {
  // Do whatever with selection
  // You do NOT need to call paste here
  // Later, in any other part of your app:
  console.log("Selection changed:", selection.text);
});
paste("my processed string to paste!");
