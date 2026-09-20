// Automates a Microsoft Store submission for an already-built .msix,
// using the classic Microsoft Store submission API
// (manage.devcenter.microsoft.com/v1.0) — not the newer
// api.store.microsoft.com API, which is for hosted exe/msi installers
// referenced by URL, not uploaded MSIX packages like this one.
//
// One-time manual prerequisite this script can't do for you: an Azure
// AD application must be associated with the Partner Center account
// (Partner Center -> Account settings -> Users -> Azure AD
// applications -> Add, assigned the "Manager" role, with a generated
// key) — there's no API for that association step itself. Once done,
// its Tenant ID / Client ID / key become STORE_TENANT_ID /
// STORE_CLIENT_ID / STORE_CLIENT_SECRET below.
//
// The app must also already have at least one submission created by
// hand in Partner Center (the actual Store listing) before this script
// can create further submissions for it — this is how "HUPI Code" was
// already submitted earlier, so that prerequisite is already met.
//
// Usage:
//   STORE_TENANT_ID=... STORE_CLIENT_ID=... STORE_CLIENT_SECRET=... STORE_APP_ID=... \
//     node build/publish-store-submission.mjs /path/to/hupi-code.msix
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const MSIX_PATH = process.argv[2];
if (!MSIX_PATH) {
	console.error('usage: publish-store-submission.mjs <path to .msix>');
	process.exit(1);
}

const TENANT_ID = requireEnv('STORE_TENANT_ID');
const CLIENT_ID = requireEnv('STORE_CLIENT_ID');
const CLIENT_SECRET = requireEnv('STORE_CLIENT_SECRET');
const APP_ID = requireEnv('STORE_APP_ID');

const API_BASE = 'https://manage.devcenter.microsoft.com/v1.0/my';

function requireEnv(name) {
	const value = process.env[name];
	if (!value) {
		console.error(`${name} not set`);
		process.exit(1);
	}
	return value;
}

async function getAccessToken() {
	const body = new URLSearchParams({
		grant_type: 'client_credentials',
		client_id: CLIENT_ID,
		client_secret: CLIENT_SECRET,
		resource: 'https://manage.devcenter.microsoft.com',
	});
	const res = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/token`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body,
	});
	if (!res.ok) {
		throw new Error(`token request failed: ${res.status} ${await res.text()}`);
	}
	const json = await res.json();
	return json.access_token;
}

async function api(token, method, urlPath, body) {
	const res = await fetch(`${API_BASE}${urlPath}`, {
		method,
		headers: {
			Authorization: `Bearer ${token}`,
			'Content-Type': 'application/json',
		},
		body: body !== undefined ? JSON.stringify(body) : undefined,
	});
	const text = await res.text();
	if (!res.ok) {
		throw new Error(`${method} ${urlPath} failed: ${res.status} ${text}`);
	}
	return text ? JSON.parse(text) : undefined;
}

async function main() {
	console.log('==> getting an Azure AD access token');
	const token = await getAccessToken();

	console.log(`==> checking for an existing in-progress submission for app ${APP_ID}`);
	const app = await api(token, 'GET', `/applications/${APP_ID}`);
	if (app.pendingApplicationSubmission?.id) {
		const pendingId = app.pendingApplicationSubmission.id;
		console.log(`    deleting stale in-progress submission ${pendingId}`);
		await api(token, 'DELETE', `/applications/${APP_ID}/submissions/${pendingId}`);
	}

	console.log('==> creating a new submission (a copy of the last published one)');
	const submission = await api(token, 'POST', `/applications/${APP_ID}/submissions`);
	const submissionId = submission.id;
	console.log(`    submission id: ${submissionId}`);

	const fileName = path.basename(MSIX_PATH);
	submission.applicationPackages = [
		{
			fileName,
			fileStatus: 'PendingUpload',
			minimumDirectXVersion: 'None',
			minimumSystemRam: 'None',
		},
	];

	console.log('==> updating the submission to reference the new package');
	await api(token, 'PUT', `/applications/${APP_ID}/submissions/${submissionId}`, submission);

	console.log('==> zipping the package for upload');
	const zipDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hupi-store-'));
	const zipPath = path.join(zipDir, 'submission.zip');
	execFileSync('zip', ['-j', zipPath, MSIX_PATH]);

	console.log(`==> uploading ${fileName} to the submission's Azure Blob SAS URL`);
	const zipBuffer = fs.readFileSync(zipPath);
	const uploadRes = await fetch(submission.fileUploadUrl, {
		method: 'PUT',
		headers: {
			'x-ms-blob-type': 'BlockBlob',
			'Content-Length': String(zipBuffer.length),
		},
		body: zipBuffer,
	});
	if (!uploadRes.ok) {
		throw new Error(`blob upload failed: ${uploadRes.status} ${await uploadRes.text()}`);
	}
	fs.rmSync(zipDir, { recursive: true, force: true });

	console.log('==> committing the submission');
	await api(token, 'POST', `/applications/${APP_ID}/submissions/${submissionId}/commit`);

	console.log('==> polling commit/ingestion status (up to ~10 minutes; full Store');
	console.log('    certification/publishing can take much longer than that — check');
	console.log('    Partner Center to follow it the rest of the way)');
	const terminalFailure = new Set([
		'CommitFailed',
		'PublishFailed',
		'PreProcessingFailed',
		'CertificationFailed',
		'ReleaseFailed',
	]);
	const deadline = Date.now() + 10 * 60 * 1000;
	let lastStatus;
	while (Date.now() < deadline) {
		const status = await api(token, 'GET', `/applications/${APP_ID}/submissions/${submissionId}/status`);
		lastStatus = status.status;
		console.log(`    status: ${lastStatus}`);
		if (terminalFailure.has(lastStatus)) {
			console.error('submission failed:', JSON.stringify(status.statusDetails, null, 2));
			process.exit(1);
		}
		if (lastStatus && !['CommitStarted', 'PendingCommit'].includes(lastStatus)) {
			break;
		}
		await new Promise((r) => setTimeout(r, 30_000));
	}

	console.log(`Submission ${submissionId} committed, last observed status: ${lastStatus}`);
	console.log(`Follow the rest of certification/publishing in Partner Center: https://partner.microsoft.com/dashboard/products/${APP_ID}/submissions/${submissionId}`);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
