import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';

import { chromium } from 'playwright-core';
import sharp from 'sharp';

const DEFAULT_SIZE = 1024;
const ANDROID_ICON_SIZES = new Map([
  ['mipmap-mdpi', 48],
  ['mipmap-hdpi', 72],
  ['mipmap-xhdpi', 96],
  ['mipmap-xxhdpi', 144],
  ['mipmap-xxxhdpi', 192],
]);
const repoRoot = path.resolve(import.meta.dirname, '..');

function parseArgs(argv) {
  const options = {
    source: 'assets/app_icon/icon.svg',
    output: 'build/app_icon/icon.png',
    androidRes: 'android/app/src/main/res',
    size: DEFAULT_SIZE,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === '--source' && next) {
      options.source = next;
      index += 1;
      continue;
    }
    if (arg === '--output' && next) {
      options.output = next;
      index += 1;
      continue;
    }
    if (arg === '--android-res' && next) {
      options.androidRes = next;
      index += 1;
      continue;
    }
    if (arg === '--size' && next) {
      options.size = Number.parseInt(next, 10) || DEFAULT_SIZE;
      index += 1;
    }
  }

  return options;
}

function resolveProjectPath(targetPath) {
  return path.isAbsolute(targetPath)
    ? path.normalize(targetPath)
    : path.join(repoRoot, targetPath);
}

function executableCandidates() {
  return [
    process.env.CHROME_PATH,
    process.env.BROWSER_PATH,
    ...lookupWithWhere('chrome.exe'),
    ...lookupWithWhere('msedge.exe'),
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  ].filter(Boolean);
}

function lookupWithWhere(command) {
  try {
    return execFileSync('where', [command], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function findBrowserExecutable() {
  for (const candidate of executableCandidates()) {
    try {
      await fs.access(candidate);
      return candidate;
    } catch {
      continue;
    }
  }

  throw new Error('未找到可用的 Chrome/Edge 浏览器，无法渲染 app icon。');
}

function buildHtmlDocument(svgMarkup, size) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <style>
      html, body {
        margin: 0;
        width: ${size}px;
        height: ${size}px;
        overflow: hidden;
        background: transparent;
      }

      body {
        display: block;
      }

      svg {
        display: block;
        width: ${size}px;
        height: ${size}px;
      }
    </style>
  </head>
  <body>${svgMarkup}</body>
</html>`;
}

async function ensureOutputDirectory(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function writeAndroidMipmaps(sourcePngPath, androidResPath) {
  const sourceBuffer = await fs.readFile(sourcePngPath);

  for (const [directoryName, targetSize] of ANDROID_ICON_SIZES.entries()) {
    const destinationDirectory = path.join(androidResPath, directoryName);
    const destinationPath = path.join(destinationDirectory, 'ic_launcher.png');
    await fs.mkdir(destinationDirectory, { recursive: true });
    await sharp(sourceBuffer)
      .resize(targetSize, targetSize)
      .png()
      .toFile(destinationPath);
  }
}

async function renderIcon({ source, output, androidRes, size }) {
  const sourcePath = resolveProjectPath(source);
  const outputPath = resolveProjectPath(output);
  const androidResPath = resolveProjectPath(androidRes);
  const browserPath = await findBrowserExecutable();
  const svgMarkup = await fs.readFile(sourcePath, 'utf8');

  await ensureOutputDirectory(outputPath);

  const browser = await chromium.launch({
    executablePath: browserPath,
    headless: true,
    args: ['--disable-gpu'],
  });

  try {
    const page = await browser.newPage({
      viewport: { width: size, height: size },
      deviceScaleFactor: 1,
    });

    await page.setContent(buildHtmlDocument(svgMarkup, size), {
      waitUntil: 'load',
    });

    const icon = page.locator('svg');
    await icon.waitFor();
    const box = await icon.boundingBox();
    if (!box) {
      throw new Error('未找到可截图的 SVG 图标节点。');
    }

    await page.screenshot({
      path: outputPath,
      omitBackground: true,
      clip: box,
    });
  } finally {
    await browser.close();
  }

  await writeAndroidMipmaps(outputPath, androidResPath);
}

const options = parseArgs(process.argv.slice(2));

renderIcon(options).catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
