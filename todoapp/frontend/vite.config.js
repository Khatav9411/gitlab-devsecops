import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', sourcemap: false },
  server: {
    // Local dev only — in prod the ingress routes /api to the api service
    proxy: { '/api': 'http://localhost:8080' },
  },
});
