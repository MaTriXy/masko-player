// esbuild's binary loader turns an imported .wasm file into its bytes.
declare module '*.wasm' {
  const bytes: Uint8Array;
  export default bytes;
}

/** The package version, set by the build. */
declare const __VERSION__: string;
