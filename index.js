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

  helper.stdout.on('data', data => {
    const result = JSON.parse(data.toString());
    onSelection(result, processedText => {
      helper.stdin.write(processedText + '\n');
    });
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
