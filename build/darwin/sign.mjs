// Signs a built VSCode-darwin-* app bundle under hardened runtime,
// mirroring microsoft/vscode's own build/darwin/sign.ts (same
// per-file entitlements switch, same preAutoEntitlements/
// preEmbedProvisioningProfile: false, same hardenedRuntime: true) —
// reused deliberately rather than hand-rolling raw codesign calls,
// since @electron/osx-sign already knows how to walk an Electron app's
// nested Frameworks/helpers/dylibs correctly and this project has no
// local Mac to verify a from-scratch signing order against.
//
// Usage: node sign.mjs <path to VSCode-darwin-arm64> <codesign identity> <keychain path>
import fs from 'node:fs';
import path from 'node:path';
import { sign } from '@electron/osx-sign';

const [, , appDir, identity, keychain] = process.argv;
if (!appDir || !identity || !keychain) {
	console.error('usage: sign.mjs <path to VSCode-darwin-arm64> <codesign identity> <keychain path>');
	process.exit(1);
}

const entitlementsDir = path.join(import.meta.dirname, 'entitlements');

function getEntitlementsForFile(filePath) {
	if (filePath.includes(' Helper (GPU).app')) {
		return path.join(entitlementsDir, 'helper-gpu-entitlements.plist');
	} else if (filePath.includes(' Helper (Renderer).app')) {
		return path.join(entitlementsDir, 'helper-renderer-entitlements.plist');
	} else if (filePath.includes(' Helper (Plugin).app')) {
		return path.join(entitlementsDir, 'helper-plugin-entitlements.plist');
	} else if (filePath.includes(' Helper.app')) {
		return path.join(entitlementsDir, 'helper-entitlements.plist');
	}
	return path.join(entitlementsDir, 'app-entitlements.plist');
}

const appName = fs.readdirSync(appDir).find((f) => f.endsWith('.app'));
if (!appName) {
	console.error(`no .app bundle found in ${appDir}`);
	process.exit(1);
}

await sign({
	app: path.join(appDir, appName),
	platform: 'darwin',
	optionsForFile: (filePath) => ({
		entitlements: getEntitlementsForFile(filePath),
		hardenedRuntime: true,
	}),
	preAutoEntitlements: false,
	preEmbedProvisioningProfile: false,
	keychain,
	identity,
});

console.log(`signed ${path.join(appDir, appName)}`);
