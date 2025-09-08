// selection-observer.js

const { spawn } = require('child_process');
const path = require('path');

let helper = null;
let listeners = [];
let ready = false;
let buffer = '';

function startHelper() {
  if (helper) return;
  const platform = process.platform;
  let helperPath;
  if (platform === 'darwin') {
    helperPath = path.join(__dirname, 'helpers', 'mac', 'selection-observer');
  } else if (platform === 'win32') {
    throw new Error('Windows support coming soon.');
  } else {
    throw new Error('Unsupported OS');
  }

  if (helperPath.includes('.asar')) {
    helperPath = helperPath.replace('.asar', '.asar.unpacked');
  }

  try {
    helper = spawn(helperPath, { stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (e) {
    console.error('[textwrench-observer] Failed to spawn helper at', helperPath, e);
    throw e;
  }

  helper.stdout.on('data', data => {
    buffer += data.toString();
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);

      if (line) {
        try {
          const result = JSON.parse(line);
          // Notify all listeners
          listeners.forEach(listener => {
            listener(result);
          });
        } catch (e) {
          console.error('Invalid JSON line:', line);
        }
      }
    }
  });

  helper.stderr.on('data', data => {
    console.error(`stderr: ${data}`);
  });

  helper.on('close', code => {
    helper = null;
    console.log(`Helper exited with code ${code}`);
  });
}

// Called to send text to paste
function paste(processedText) {
  if (!helper) {
    startHelper();
  }

  // Handle both string and object input
  let dataToSend;
  if (typeof processedText === 'object' && processedText !== null) {
    // If it's an object, stringify it
    dataToSend = JSON.stringify(processedText);
  } else {
    // If it's a string, use it directly (backward compatibility)
    dataToSend = String(processedText);
  }

  helper.stdin.write(dataToSend + '\n');
}

// Listen for selections
function onSelection(callback) {
  startHelper();

  // Wrap the callback to allow for disposable listeners
  const wrappedCallback = (result) => {
    const shouldRemove = callback(result);
    if (shouldRemove === true) {
      const index = listeners.indexOf(wrappedCallback);
      if (index !== -1) {
        listeners.splice(index, 1);
      }
    }
  };

  listeners.push(wrappedCallback);
  return {
    dispose: () => {
      const index = listeners.indexOf(wrappedCallback);
      if (index !== -1) {
        listeners.splice(index, 1);
      }
    }
  };
}

module.exports = { onSelection, paste };
