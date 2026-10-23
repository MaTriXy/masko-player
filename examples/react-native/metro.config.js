// The package comes from ../../react-native (a file: dependency). Metro reads
// its sources there, and takes React and React Native only from this app.
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const config = getDefaultConfig(__dirname);
const pkg = path.resolve(__dirname, '../../react-native');

config.watchFolders = [pkg];
config.resolver.nodeModulesPaths = [path.resolve(__dirname, 'node_modules')];
config.resolver.blockList = [
  ...Array.from(config.resolver.blockList ?? []),
  new RegExp(`^${path.join(pkg, 'node_modules').replace(/[/\\.]/g, '\\$&')}/.*`)
];

module.exports = config;
