import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts", "src/realtime-entry.ts"],
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  treeshake: true,
  target: "es2022",
});
