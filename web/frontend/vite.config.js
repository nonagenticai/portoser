import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// React 19 ships its JSX runtimes as CJS modules wrapped in a
// `(function () { ... })()` IIFE that's gated on `process.env.NODE_ENV`.
// Vite's CJS->ESM prebundle (via esbuild's cjs-module-lexer) can't see
// `exports.jsxDEV = ...` inside that IIFE, so the prebundled module
// only re-exposes a `default`. Browsers then fail with
//   `SyntaxError: ... does not provide an export named 'jsxDEV'`.
//
// This plugin appends named re-exports to the prebundled modules so the
// auto-injected `import { jsxDEV } from 'react/jsx-dev-runtime'` from
// @vitejs/plugin-react resolves correctly.
function fixReact19JsxRuntimeExports() {
  const targets = [
    /\/\.vite\/deps\/react_jsx-dev-runtime\.js$/,
    /\/\.vite\/deps\/react_jsx-runtime\.js$/,
  ]
  return {
    name: 'portoser:fix-react19-jsx-runtime-exports',
    enforce: 'post',
    apply: 'serve',
    transform(code, id) {
      if (!targets.some((re) => re.test(id))) return null
      if (!/export default\s+(\w+)\(\)/.test(code)) return null
      // Capture the existing `export default REQ()` and replace with a
      // hoisted const + named re-exports. The names mirror what plugin-react
      // imports: `jsxDEV` / `jsx` / `jsxs` / `Fragment`.
      const wrapped = code.replace(
        /export default (\w+)\(\);?$/m,
        (_, fn) =>
          `const __r = ${fn}();\n` +
          `export default __r;\n` +
          `export const Fragment = __r.Fragment;\n` +
          `export const jsx = __r.jsx;\n` +
          `export const jsxs = __r.jsxs;\n` +
          `export const jsxDEV = __r.jsxDEV;\n`
      )
      return { code: wrapped, map: null }
    },
  }
}

// Vite only injects VITE_* into `import.meta.env`, not `process.env` — so
// reading `process.env.VITE_*` here would silently ignore .env. Use
// `loadEnv` to pick those values up at config time.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  return {
  plugins: [react(), fixReact19JsxRuntimeExports()],
  resolve: {
    extensions: ['.mjs', '.js', '.mts', '.ts', '.jsx', '.tsx', '.json'],
  },
  build: {
    // Pre-existing build emitted a single ~750KB chunk. Split out the
    // heaviest libs into their own files so the initial paint loads less
    // JS and the long tail caches independently.
    rollupOptions: {
      output: {
        // Split the heaviest libs into their own files — Reactflow alone
        // is ~150KB and only mounts on the dependency-graph page. (We
        // don't bother splitting react/react-dom: they're tiny and
        // imported everywhere, so a separate chunk just costs a request.)
        manualChunks: {
          reactflow: ['reactflow'],
          'react-dnd': ['react-dnd', 'react-dnd-html5-backend'],
          tanstack: ['@tanstack/react-query'],
        },
      },
    },
    chunkSizeWarningLimit: 600,
  },
  server: {
    port: parseInt(env.VITE_DEV_PORT || '8989'),
    proxy: {
      '/api': {
        target: env.VITE_API_URL || 'http://localhost:8988',
        changeOrigin: true,
      },
      '/ws': {
        target: env.VITE_WS_URL || 'ws://localhost:8988',
        ws: true,
      }
    }
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: './src/test/setup.js',
    server: {
      deps: {
        // vitest 4 follows ESM-strict resolution; let vite's bundler-style
        // resolution apply to test code so local imports without `.js`
        // extensions keep working.
        inline: [],
      },
    },
  },
  // vitest 4 re-uses vite's resolve.extensions, but we make it explicit
  // here so the order matches build expectations.
  optimizeDeps: {
    extensions: ['.jsx', '.tsx', '.js', '.ts'],
    // React 19's CJS jsx runtimes wrap everything in an IIFE gated on
    // `process.env.NODE_ENV !== 'production'`. When Vite prebundles
    // those modules, esbuild's static `cjs-module-lexer` can't see
    // `exports.jsxDEV = ...` inside the IIFE, so it only re-exposes a
    // `default` and the dev server fails with
    //   `SyntaxError: ... does not provide an export named 'jsxDEV'`.
    // Define NODE_ENV up-front so esbuild can fold the conditional and
    // pick up the named exports during prebundling.
    esbuildOptions: {
      define: {
        'process.env.NODE_ENV': JSON.stringify('development'),
      },
    },
  },
  }
})
