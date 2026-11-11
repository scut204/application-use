// Pure evidence classification: desktop activity is inconclusive because a
// user can move a mouse or change windows while the test is running.
export function classifyMonitor(events, {requireWindow = true} = {}) {
  const ready = events.find(event => event.event === 'ready');
  if (!ready) return {status: 'incomplete', reason: 'Monitor did not initialize'};
  const activityKinds = new Set(['pointer-change', 'foreground-change', 'focused-window-change', 'window-notification']);
  const activity = events.filter(event => activityKinds.has(event.event) ||
    (event.event === 'application-activation' && !event.isSentinel));
  if (activity.length) return {status: 'inconclusive-desktop-activity', activity};
  const heartbeat = events.filter(event => event.event === 'heartbeat').at(-1);
  if (!heartbeat || heartbeat.samples < 10) return {status: 'incomplete', reason: 'Too few monitor samples'};
  if (requireWindow && (!ready.focusedWindowAvailable || !Object.values(ready.windowNotifications ?? {}).includes(0))) {
    return {status: 'incomplete', reason: 'Foreground focused-window observation unavailable'};
  }
  if (heartbeat.windowReadFailures > 0) return {status: 'incomplete', reason: 'Foreground window reads failed'};
  if (heartbeat.maxPollGapMs > 150) return {status: 'incomplete', reason: 'Monitor sampling gap exceeded 150 ms', maxPollGapMs: heartbeat.maxPollGapMs};
  return {status: 'passed-observed-interval', samples: heartbeat.samples, maxPollGapMs: heartbeat.maxPollGapMs,
    focusedWindowObserved: ready.focusedWindowAvailable, limitation: 'Notification-assisted sampling cannot prove zero-duration disturbance'};
}

export function findLabel(snapshot, title) {
  const lines = snapshot.split('\n').filter(line => line.includes(title));
  for (const line of lines) {
    const match = line.match(/^\s*\[?([A-Z]+)\]?(?:\s|[.:)])/);
    if (match) return match[1];
  }
  throw new Error(`Cannot find an application-use letter for ${title}: ${lines.join('\n')}`);
}

export function findFixtureLabel(snapshot, ...titles) {
  const axLines = snapshot.split('\n').filter(line => /^\s*\[[A-Z]+\]\s+AX\s/.test(line)).join('\n');
  for (const title of titles) {
    try { return findLabel(axLines, title); } catch { /* Try the fixture's alternate AX title. */ }
  }
  throw new Error(`Cannot find a fixture AX hint for ${titles.join(' / ')}. Fixture AX hints:\n${axLines}`);
}
