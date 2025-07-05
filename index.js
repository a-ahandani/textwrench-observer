const { spawn } = require('child_process');
const path = require('path');

function startSelectionObserver(onSelection) {
  const platform = process.platform;
  let helperPath;

  if (platform === 'darwin') {
    helperPath = path.join(__dirname, 'helpers', 'mac', 'selection-observer');
  } else if (platform === 'win32') {
    throw new Error('Windows support coming soon.');
  } else {
    throw new Error('Unsupported OS');
  }

  const helper = spawn(helperPath);

  let buffer = '';

  helper.stdout.on('data', data => {
    buffer += data.toString();
  
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
  
      if (line) {
        try {
          const result = JSON.parse(line);
          onSelection(result, processedText => {
            helper.stdin.write(processedText + '\n');
          });
        } catch (e) {
          console.error('Invalid JSON line:', line);
          console.error(e);
        }
      }
    }
  });

  

  helper.stderr.on('data', data => {
    console.error(`stderr: ${data}`);
  });

  helper.on('close', code => {
    console.log(`Helper exited with code ${code}`);
  });

  return helper;
}

module.exports = { startSelectionObserver };
