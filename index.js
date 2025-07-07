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

  helper = spawn(helperPath);

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
  if (helper) {
    helper.stdin.write(processedText + '\n');
  }
}

// Listen for selections
function onSelection(callback) {
  startHelper();
  listeners.push(callback);
}

module.exports = { onSelection, paste };
