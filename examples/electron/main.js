// A mascot on the desktop: a frameless, transparent window that stays on top,
// in the bottom-right corner. The page (index.html) runs @masko/player like
// any web page; nothing here is specific to the player.
const { app, BrowserWindow, screen } = require('electron');

const SIZE = 240;

app.whenReady().then(() => {
  const { workArea } = screen.getPrimaryDisplay();
  const win = new BrowserWindow({
    width: SIZE,
    height: SIZE,
    x: workArea.x + workArea.width - SIZE - 24,
    y: workArea.y + workArea.height - SIZE - 24,
    frame: false,
    transparent: true,
    hasShadow: false,
    resizable: false,
    alwaysOnTop: true
  });
  // The page's mascot events, in this terminal.
  win.webContents.on('console-message', (event) => console.log(event.message));
  win.loadFile('index.html');
});

app.on('window-all-closed', () => app.quit());
