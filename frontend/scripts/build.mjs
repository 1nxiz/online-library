// Збірка (bundling) фронтенду: копіює src/ у dist/ і додає build-info.json.
import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';

rmSync('dist', { recursive: true, force: true });
mkdirSync('dist');
cpSync('src', 'dist', { recursive: true });
writeFileSync(
  'dist/build-info.json',
  JSON.stringify({ builtAt: new Date().toISOString(), commit: process.env.GITHUB_SHA || 'local' }, null, 2),
);
console.log('Frontend built into dist/');
