#!/usr/bin/env node
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync, appendFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {classifyMonitor, findLabel, findFixtureLabel} from './verification.mjs';

// No GUI is launched unless --run is explicit. The default is compile-only.
const argv = process.argv.slice(2);
function option(name) { const index = argv.indexOf(name); return index < 0 ? undefined : argv[index + 1]; }
const run = argv.includes('--run');
const demonstration = argv.includes('--demo');
const cliPath = option('--cli') && path.resolve(option('--cli'));
const runtimePath = option('--runtime') && path.resolve(option('--runtime'));
assert.equal(process.platform, 'darwin', 'This acceptance test requires macOS');
assert.ok(!run || cliPath, '--run requires --cli /path/to/application-use');
assert.ok(!argv.includes('--allow-desktop-activity'), 'Desktop activity must not be ignored');
const root = mkdtempSync(path.join(tmpdir(), 'application-use-background-test-'));
const source = fileURLToPath(new URL('./BackgroundProbe.swift', import.meta.url));
const executable = path.join(root, 'BackgroundProbe');
const recorderExecutable = path.join(root, 'WindowDemoRecorder');
const recorderStopPath = path.join(root, 'stop-recording');
const demoGIF = option('--output') ? path.resolve(option('--output')) : path.join(root, 'cursor-demo.gif');
const statePath = path.join(root, 'fixture-state.json');
const screenshotPath = path.join(root, 'fixture-only.png');
const eventsPath = path.join(root, 'monitor.jsonl');
const reportPath = path.join(root, 'report.json');
const fixtureEventsPath = path.join(root, 'fixture.jsonl');
const appName = 'ApplicationUseBackgroundProbe';
const appRoot = path.join(root, `${appName}.app`);
const fixtureExecutable = path.join(appRoot, 'Contents', 'MacOS', appName);
const session = `acceptance-${process.pid}-${Date.now()}`;
const env = {...process.env, APPLICATION_USE_SESSION:session,
  ...(runtimePath ? {APPLICATION_USE_RUNTIME:runtimePath} : {})};
const events = [];
const steps = [];
let monitor, fixture, monitorBuffer = '', fixtureErrors = '', sessionUsed = false;
let recorder, recorderDone, recorderBuffer = '';
const recorderEvents = [];
let result = {status:'incomplete', mode:demonstration ? 'visible-cursor-demo' : 'occluded-acceptance', reportPath, session, steps};
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const fixtureState = () => JSON.parse(readFileSync(statePath, 'utf8'));

async function waitFor(predicate, description, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (fixture?.exitCode !== null && fixture?.exitCode !== undefined) throw new Error(`Fixture exited: ${fixtureErrors}`);
    assert.ok(Date.now() < deadline, `Timed out: ${description}`);
    await sleep(30);
  }
}

function execute(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {env, stdio:['ignore','pipe','pipe'], ...options});
    let stdout = '', stderr = '';
    const timer = setTimeout(() => { child.kill('SIGTERM'); }, 30000);
    const killTimer = setTimeout(() => { child.kill('SIGKILL'); }, 32000);
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.once('error', error => { clearTimeout(timer); clearTimeout(killTimer); reject(error); });
    child.once('exit', (code, signal) => { clearTimeout(timer); clearTimeout(killTimer); resolve({code, signal, stdout, stderr}); });
  });
}

async function cli(args, {reject = false} = {}) {
  if (args[0] !== '_shutdown') sessionUsed = true;
  const command = cliPath.endsWith('.py') ? 'python3' : cliPath;
  const processArgs = cliPath.endsWith('.py') ? [cliPath, ...args] : args;
  const response = await execute(command, processArgs);
  assert.equal(response.signal, null, `CLI timed out: ${args[0]}`);
  if (reject) assert.notEqual(response.code, 0, `Unsupported operation unexpectedly succeeded: ${response.stdout}`);
  else assert.equal(response.code, 0, `${args[0]} failed: ${response.stderr}\n${response.stdout}`);
  return response;
}

async function step(name, action) {
  const start = Date.now();
  const eventStart = events.length;
  try {
    await action();
    await sleep(180);
    const current = fixtureState();
    assert.equal(current.isActive, false, 'Fixture became the active application');
    // Synthetic target-local key state is allowed; global foreground-window
    // stability is independently observed by the monitor.
    steps.push({name, status:'passed', durationMs:Date.now() - start, eventStart, eventEnd:events.length});
  } catch (error) {
    steps.push({name, status:'failed', error:String(error.message), durationMs:Date.now() - start, eventStart, eventEnd:events.length});
    throw error;
  }
}

async function stopOwned(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  await new Promise(resolve => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 2000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

async function finishRecording() {
  if (!recorderDone) return;
  if (recorder.exitCode === null && recorder.signalCode === null) writeFileSync(recorderStopPath, 'stop\n');
  const timer = setTimeout(() => recorder.kill('SIGTERM'), 10000);
  const code = await recorderDone;
  clearTimeout(timer);
  result.recording = recorderEvents.findLast(event => event.event === 'recording-complete')
    ?? {status:'failed', code, error:recorderEvents.find(event => event.event === 'recording-error')?.error};
  result.demoGIF = existsSync(demoGIF) ? demoGIF : undefined;
}

try {
  const build = spawnSync('swiftc', ['-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx15.0`, source, '-o', executable], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stderr);
  steps.push({name:'compile-macos15-probe', status:'passed'});
  if (demonstration) {
    const recorderBuild = spawnSync('swiftc', ['-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx15.0`,
      fileURLToPath(new URL('./WindowDemoRecorder.swift', import.meta.url)), '-o', recorderExecutable], {encoding:'utf8'});
    assert.equal(recorderBuild.status, 0, recorderBuild.stderr);
    steps.push({name:'compile-isolated-window-recorder', status:'passed'});
  }
  if (!run) {
    result.status = 'build-only-passed';
    result.executable = executable;
  } else {
    // Start monitoring before doctor or fixture launch to include setup in the
    // observed interval. Neither the monitor nor doctor should display UI.
    monitor = spawn(executable, ['--monitor'], {stdio:['ignore','pipe','pipe']});
    monitor.stdout.on('data', data => {
      monitorBuffer += data.toString();
      let end;
      while ((end = monitorBuffer.indexOf('\n')) >= 0) {
        const line = monitorBuffer.slice(0, end); monitorBuffer = monitorBuffer.slice(end + 1);
        if (!line) continue;
        try { const event = JSON.parse(line); events.push(event); appendFileSync(eventsPath, `${line}\n`); }
        catch { result.monitorParseError = true; }
      }
    });
    monitor.stderr.on('data', data => appendFileSync(path.join(root, 'monitor-stderr.txt'), data));
    await waitFor(() => events.some(event => event.event === 'ready'), 'read-only monitor initialization');
    const ready = events.find(event => event.event === 'ready');
    assert.ok(ready.sentinelPID > 0, 'No foreground application to use as a sentinel');
    assert.ok(ready.focusedWindowAvailable, 'Foreground focused-window observation is unavailable; no GUI fixture was started');
    const doctor = await cli(['doctor']);
    result.permissions = JSON.parse(doctor.stdout);
    assert.equal(result.permissions.allGranted, true, 'Automation permissions are missing; no GUI fixture was started');
    if (demonstration) {
      assert.equal(result.permissions.visualCursorEnabled, true, 'This runtime has not enabled the real visual cursor');
      assert.ok(Number.isInteger(result.permissions.runtimePID) && result.permissions.runtimePID > 0, 'Runtime PID is required to identify the real cursor window');
      assert.equal(existsSync(demoGIF), false, 'Demo GIF output already exists');
      mkdirSync(path.dirname(demoGIF), {recursive:true});
    }

    mkdirSync(path.dirname(fixtureExecutable), {recursive:true});
    copyFileSync(executable, fixtureExecutable);
    writeFileSync(path.join(appRoot, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>${appName}</string>
<key>CFBundleIdentifier</key><string>local.application-use.background-probe.${process.pid}</string>
<key>CFBundleName</key><string>${appName}</string><key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string></dict></plist>`);
    fixture = spawn(fixtureExecutable, [demonstration ? '--demo-fixture' : '--fixture', statePath], {stdio:['ignore','pipe','pipe']});
    fixture.stdout.on('data', data => appendFileSync(fixtureEventsPath, data));
    fixture.stderr.on('data', data => { fixtureErrors += data; });
    await waitFor(() => existsSync(statePath), 'background fixture initialization');
    await sleep(300);
    assert.equal(fixtureState().sentinelPID, ready.sentinelPID, 'Foreground changed during setup');
    assert.equal(fixtureState().isActive, false, 'Starting the fixture activated it');

    let snapshot;
    const observe = async () => { snapshot = (await cli(['snapshot', '--appName', appName])).stdout; return snapshot; };
    if (demonstration) {
      await observe();
      recorder = spawn(recorderExecutable, [statePath, String(result.permissions.runtimePID), demoGIF, recorderStopPath, '45'],
        {stdio:['ignore','pipe','pipe']});
      recorderDone = new Promise(resolve => {
        recorder.once('exit', code => resolve(code));
        recorder.once('error', error => { recorderEvents.push({event:'recording-error', error:String(error)}); resolve(-1); });
      });
      recorder.stdout.on('data', data => {
        recorderBuffer += data.toString();
        let end;
        while ((end = recorderBuffer.indexOf('\n')) >= 0) {
          const line = recorderBuffer.slice(0, end); recorderBuffer = recorderBuffer.slice(end + 1);
          if (!line) continue;
          try { recorderEvents.push(JSON.parse(line)); appendFileSync(path.join(root, 'recorder.jsonl'), `${line}\n`); }
          catch { recorderEvents.push({event:'recording-error', error:'Malformed recorder output'}); }
        }
      });
      recorder.stderr.on('data', data => appendFileSync(path.join(root, 'recorder-stderr.txt'), data));
      await waitFor(() => recorderEvents.some(event => event.event === 'recording-ready') || recorder.exitCode !== null, 'isolated recorder initialization');
      assert.ok(recorderEvents.some(event => event.event === 'recording-ready'), JSON.stringify(recorderEvents));
      const demoStarted = Date.now();
      await sleep(600);
      for (const action of [
        {name:'demo-left-click', titles:['左侧目标', 'Background increment'], field:'clicks'},
        {name:'demo-right-click', titles:['右侧目标', 'Demo right target'], field:'rightClicks'},
        {name:'demo-text-entry', titles:['Background text'], text:'代理光标正在后台操作'},
        {name:'demo-lower-click', titles:['下方目标', 'Demo lower target'], field:'lowerClicks'},
        {name:'demo-return-left', titles:['左侧目标', 'Background increment'], field:'clicks'},
      ]) {
        await step(action.name, async () => {
          const before = fixtureState();
          const hint = findFixtureLabel(snapshot, ...action.titles);
          const args = action.text ? ['fill', hint, action.text] : ['click', hint];
          snapshot = (await cli([...args, '--appName', appName])).stdout;
          await waitFor(() => action.text ? fixtureState().text === action.text : fixtureState()[action.field] === before[action.field] + 1,
            `real receiver effect for ${action.name}`);
          await sleep(650);
        });
      }
      await sleep(Math.max(0, 18000 - (Date.now() - demoStarted)));
      await finishRecording();
      assert.equal(result.recording.status, 'passed', JSON.stringify(result.recording));
      result.demoElapsedSeconds = (Date.now() - demoStarted) / 1000;
      await step('cursor-hides-after-target-exits', async () => {
        // Finalize real footage first, then remove only our target while its
        // automation runtime is still alive. No session-stop can mask a leak.
        await stopOwned(fixture);
        await sleep(350);
        const inspected = await execute(recorderExecutable, ['--inspect-cursor', String(result.permissions.runtimePID)]);
        assert.equal(inspected.code, 0, inspected.stderr);
        result.cursorAfterTargetExit = JSON.parse(inspected.stdout);
        assert.equal(result.cursorAfterTargetExit.runtimeAlive, true, 'Runtime exited before target-loss cleanup could be checked');
        assert.deepEqual(result.cursorAfterTargetExit.visibleWindows, [], 'Cursor remained visible after its target window exited');
      });
    } else {
    await step('snapshot-real-appkit', async () => {
      await observe();
      findLabel(snapshot, 'Background increment');
      findLabel(snapshot, 'Background text');
      findLabel(snapshot, 'Background scroll');
    });
    await step('occluded-target-screenshot', async () => {
      assert.equal(fixtureState().occludedBySentinel, true,
        'Sentinel does not fully cover the fixture; occluded-capture coverage is unavailable');
      await cli(['screenshot', screenshotPath, '--appName', appName]);
      const checked = await execute(executable, ['--inspect-image', screenshotPath]);
      result.screenshot = JSON.parse(checked.stdout);
      assert.equal(checked.code, 0, `Capture did not contain the fixture marker: ${checked.stdout}`);
      const frame = fixtureState().windowBounds;
      assert.ok(Math.abs(result.screenshot.width / result.screenshot.height - frame[2] / frame[3]) < 0.03,
        'Screenshot proportions do not match the fixture window');
      assert.ok(result.screenshot.markerFraction > 0.05, 'Too little fixture marker content in the screenshot');
      assert.equal(fixtureState().occludedBySentinel, true, 'Fixture was raised above its occluder');
      unlinkSync(screenshotPath);
    });
    await step('click-real-button', async () => {
      const before = fixtureState().clicks;
      await observe();
      await cli(['click', findLabel(snapshot, 'Background increment'), '--appName', appName]);
      await waitFor(() => fixtureState().clicks === before + 1, 'AX button activation');
    });
    await step('fill-real-text', async () => {
      await observe();
      await cli(['fill', findLabel(snapshot, 'Background text'), '后台🙂 é', '--appName', appName]);
      await waitFor(() => fixtureState().text === '后台🙂 é', 'verified fixture text insertion');
    });
    await step('sendkey-real-receiver', async () => {
      const before = fixtureState().keyCount;
      await cli(['sendkey', 'Right', '--appName', appName]);
      await waitFor(() => fixtureState().keyCount > before, 'process-directed key event delivery');
    });
    await step('scroll-real-content', async () => {
      await observe();
      const before = fixtureState().scrollY;
      await cli(['scroll', findLabel(snapshot, 'Background scroll'), 'down', '--appName', appName]);
      await waitFor(() => fixtureState().scrollY > before, 'fixture document scrolling');
    });
    await step('unsupported-input-is-refused', async () => {
      await observe();
      const before = fixtureState();
      const rejected = await cli(['click', findLabel(snapshot, 'Background increment'), '--right', '--appName', appName], {reject:true});
      assert.match(`${rejected.stdout}\n${rejected.stderr}`, /unsupported|not supported|unrecognized|right|background/i);
      await sleep(150);
      const after = fixtureState();
      for (const field of ['clicks','text','scrollY','keyCount','closeAttempts']) assert.deepEqual(after[field], before[field]);
    });
    await step('fill-button-is-refused-before-click', async () => {
      await observe();
      const before = fixtureState();
      const rejected = await cli(['fill', findLabel(snapshot, 'Background increment'), 'MUST NOT TYPE', '--appName', appName], {reject:true});
      assert.match(`${rejected.stdout}\n${rejected.stderr}`, /text|edit|focus|input|fill/i);
      await sleep(150);
      const after = fixtureState();
      for (const field of ['clicks','text','scrollY','keyCount','closeAttempts','activations','windowNumber']) {
        assert.deepEqual(after[field], before[field], `Rejected fill changed ${field}`);
      }
    });
    await step('window-management-keys-are-refused', async () => {
      // Parse aliases and extra modifiers must not bypass the same native guard.
      for (const key of ['cmd+q', 'command+w', 'super+m', 'meta+h', 'cmd+tab',
        'cmd+option+h', 'cmd+shift+w', 'cmd+space', 'control+command+f',
        'ctrl+command+q', 'command+alt+escape', 'ctrl+left']) {
        // A refused native action invalidates its snapshot intentionally.
        await observe();
        const before = fixtureState();
        const rejected = await cli(['sendkey', key, '--appName', appName], {reject:true});
        assert.match(`${rejected.stdout}\n${rejected.stderr}`, /background|unavailable|refus|not supported|unsupported|not allowed|forbid|denied/i);
        await sleep(80);
        const after = fixtureState();
        for (const field of ['clicks','text','scrollY','keyCount','closeAttempts','activations','isActive','windowNumber']) {
          assert.deepEqual(after[field], before[field], `Rejected ${key} changed ${field}`);
        }
      }
    });
    }
    await sleep(250);
    result.fixture = fixtureState();
    result.monitor = classifyMonitor(events);
    assert.equal(result.monitorParseError, undefined, 'Monitor evidence could not be parsed');
    result.status = result.monitor.status === 'passed-observed-interval' ? 'passed' : result.monitor.status;
  }
} catch (error) {
  result.error = String(error.message);
  result.monitor = classifyMonitor(events);
  result.status = result.monitor.status === 'inconclusive-desktop-activity' ? result.monitor.status : 'failed';
  if (existsSync(statePath)) result.fixture = fixtureState();
} finally {
  // Only handles returned by our spawn calls may be terminated; no name-based
  // kill, no activation restoration, no manipulation of pre-existing windows.
  await finishRecording();
  if (sessionUsed) {
    try {
      await cli(['_shutdown']);
      result.sessionCleanup = 'passed';
    } catch (error) {
      result.sessionCleanup = String(error.message);
      if (result.status === 'passed') result.status = 'failed';
    }
  }
  const monitorWasAlive = !run || (monitor && monitor.exitCode === null && monitor.signalCode === null);
  await stopOwned(fixture);
  await sleep(run ? 250 : 0);
  await stopOwned(monitor);
  if (run) {
    result.monitor = classifyMonitor(events);
    if (!monitorWasAlive) {
      result.monitor = {status:'incomplete', reason:'Monitor stopped before acceptance finished'};
      if (result.status === 'passed') result.status = 'failed';
    } else if (result.monitor.status === 'inconclusive-desktop-activity') {
      result.status = result.monitor.status;
    } else if (result.status === 'passed' && result.monitor.status !== 'passed-observed-interval') {
      result.status = result.monitor.status;
    }
  }
  // A failed fixture capture is retained for diagnosis; successful captures are
  // deleted immediately after their content and geometry checks above.
  if (existsSync(screenshotPath)) result.diagnosticScreenshot = screenshotPath;
  result.artifacts = {root, monitor:eventsPath, fixture:fixtureEventsPath};
  writeFileSync(reportPath, `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(demonstration ? {status:result.status, mode:result.mode, reportPath,
    demoGIF:result.demoGIF, demoElapsedSeconds:result.demoElapsedSeconds,
    monitor:result.monitor?.status, recording:result.recording?.status, error:result.error,
    steps:steps.map(({name,status}) => ({name,status}))} : result, null, 2));
  if (!['passed','build-only-passed'].includes(result.status)) process.exitCode = 1;
}
